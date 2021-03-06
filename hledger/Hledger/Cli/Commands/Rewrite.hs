{-# LANGUAGE OverloadedStrings, LambdaCase, DeriveTraversable, ViewPatterns, QuasiQuotes #-}
{-# LANGUAGE CPP #-}

module Hledger.Cli.Commands.Rewrite (
  rewritemode
 ,rewrite
) 
where

#if !(MIN_VERSION_base(4,11,0))
import Control.Monad.Writer
#endif
import Data.Functor.Identity
import Data.List (sortOn, foldl')
import Data.String.Here
import qualified Data.Text as T
import Hledger
import Hledger.Cli.CliOptions
import Hledger.Cli.Commands.Print
import System.Console.CmdArgs.Explicit
import Text.Printf
import Text.Megaparsec
import qualified Data.Algorithm.Diff as D

rewritemode = hledgerCommandMode
  [here| rewrite
Print all transactions, rewriting the postings of matched transactions.
For now the only rewrite available is adding new postings, like print --auto.

FLAGS

This is a start at a generic rewriter of transaction entries.
It reads the default journal and prints the transactions, like print,
but adds one or more specified postings to any transactions matching QUERY.
The posting amounts can be fixed, or a multiplier of the existing transaction's first posting amount. 

Examples:
```
hledger-rewrite.hs ^income --add-posting '(liabilities:tax)  *.33  ; income tax' --add-posting '(reserve:gifts)  $100'
hledger-rewrite.hs expenses:gifts --add-posting '(reserve:gifts)  *-1"'
hledger-rewrite.hs -f rewrites.hledger
```
rewrites.hledger may consist of entries like:
```
= ^income amt:<0 date:2017
  (liabilities:tax)  *0.33  ; tax on income
  (reserve:grocery)  *0.25  ; reserve 25% for grocery
  (reserve:)  *0.25  ; reserve 25% for grocery
```
Note the single quotes to protect the dollar sign from bash, 
and the two spaces between account and amount.

More:

```shell
$ hledger rewrite -- [QUERY]        --add-posting "ACCT  AMTEXPR" ...
$ hledger rewrite -- ^income        --add-posting '(liabilities:tax)  *.33'
$ hledger rewrite -- expenses:gifts --add-posting '(budget:gifts)  *-1"'
$ hledger rewrite -- ^income        --add-posting '(budget:foreign currency)  *0.25 JPY; diversify'
```

Argument for `--add-posting` option is a usual posting of transaction with an
exception for amount specification. More precisely, you can use `'*'` (star
symbol) before the amount to indicate that that this is a factor for an
amount of original matched posting.  If the amount includes a commodity name,
the new posting amount will be in the new commodity; otherwise, it will be in
the matched posting amount's commodity.

#### Re-write rules in a file

During the run this tool will execute so called
["Automated Transactions"](http://ledger-cli.org/3.0/doc/ledger3.html#Automated-Transactions)
found in any journal it process. I.e instead of specifying this operations in
command line you can put them in a journal file.

```shell
$ rewrite-rules.journal
```

Make contents look like this:

```journal
= ^income
    (liabilities:tax)  *.33

= expenses:gifts
    budget:gifts  *-1
    assets:budget  *1
```

Note that `'='` (equality symbol) that is used instead of date in transactions
you usually write. It indicates the query by which you want to match the
posting to add new ones.

```shell
$ hledger rewrite -- -f input.journal -f rewrite-rules.journal > rewritten-tidy-output.journal
```

This is something similar to the commands pipeline:

```shell
$ hledger rewrite -- -f input.journal '^income' --add-posting '(liabilities:tax)  *.33' \
  | hledger rewrite -- -f - expenses:gifts      --add-posting 'budget:gifts  *-1'       \
                                                --add-posting 'assets:budget  *1'       \
  > rewritten-tidy-output.journal
```

It is important to understand that relative order of such entries in journal is
important. You can re-use result of previously added postings.

#### Diff output format

To use this tool for batch modification of your journal files you may find
useful output in form of unified diff.

```shell
$ hledger rewrite -- --diff -f examples/sample.journal '^income' --add-posting '(liabilities:tax)  *.33'
```

Output might look like:

```diff
--- /tmp/examples/sample.journal
+++ /tmp/examples/sample.journal
@@ -18,3 +18,4 @@
 2008/01/01 income
-    assets:bank:checking  $1
+    assets:bank:checking            $1
     income:salary
+    (liabilities:tax)                0
@@ -22,3 +23,4 @@
 2008/06/01 gift
-    assets:bank:checking  $1
+    assets:bank:checking            $1
     income:gifts
+    (liabilities:tax)                0
```

If you'll pass this through `patch` tool you'll get transactions containing the
posting that matches your query be updated. Note that multiple files might be
update according to list of input files specified via `--file` options and
`include` directives inside of these files.

Be careful. Whole transaction being re-formatted in a style of output from
`hledger print`.

See also: 

https://github.com/simonmichael/hledger/issues/99

#### rewrite vs. print --auto

This command predates print --auto, and currently does much the same thing,
but with these differences:

- with multiple files, rewrite lets rules in any file affect all other files.
  print --auto uses standard directive scoping; rules affect only child files.

- rewrite's query limits which transactions can be rewritten; all are printed.
  print --auto's query limits which transactions are printed.

- rewrite applies rules specified on command line or in the journal.
  print --auto applies rules specified in the journal.

  |]
  [flagReq ["add-posting"] (\s opts -> Right $ setopt "add-posting" s opts) "'ACCT  AMTEXPR'"
           "add a posting to ACCT, which may be parenthesised. AMTEXPR is either a literal amount, or *N which means the transaction's first matched amount multiplied by N (a decimal number). Two spaces separate ACCT and AMTEXPR."
  ,flagNone ["diff"] (setboolopt "diff") "generate diff suitable as an input for patch tool"
  ]
  [generalflagsgroup1]
  []
  ([], Just $ argsFlag "[QUERY] --add-posting \"ACCT  AMTEXPR\" ...")
------------------------------------------------------------------------------

-- TODO regex matching and interpolating matched name in replacement
-- TODO interpolating match groups in replacement
-- TODO allow using this on unbalanced entries, eg to rewrite while editing

rewrite opts@CliOpts{rawopts_=rawopts,reportopts_=ropts} j@Journal{jtxns=ts} = do 
  -- create re-writer
  let modifiers = transactionModifierFromOpts opts : jtxnmodifiers j
      applyallmodifiers = foldr (flip (.) . transactionModifierToFunction) id modifiers
  -- rewrite matched transactions
  let j' = j{jtxns=map applyallmodifiers ts}
  -- run the print command, showing all transactions, or show diffs
  printOrDiff rawopts opts{reportopts_=ropts{query_=""}} j j'

-- | Build a 'TransactionModifier' from any query arguments and --add-posting flags
-- provided on the command line, or throw a parse error.
transactionModifierFromOpts :: CliOpts -> TransactionModifier
transactionModifierFromOpts CliOpts{rawopts_=rawopts,reportopts_=ropts} = 
  TransactionModifier{tmquerytxt=q, tmpostingrules=ps}
  where
    q = T.pack $ query_ ropts
    ps = map (parseposting . stripquotes . T.pack) $ listofstringopt "add-posting" rawopts
    parseposting t = either (error' . errorBundlePretty) id ep
      where
        ep = runIdentity (runJournalParser (postingp Nothing True <* eof) t')
        t' = " " <> t <> "\n" -- inject space and newline for proper parsing

printOrDiff :: RawOpts -> (CliOpts -> Journal -> Journal -> IO ())
printOrDiff opts
    | boolopt "diff" opts = const diffOutput
    | otherwise = flip (const print')

diffOutput :: Journal -> Journal -> IO ()
diffOutput j j' = do
    let changed = [(originalTransaction t, originalTransaction t') | (t, t') <- zip (jtxns j) (jtxns j'), t /= t']
    putStr $ renderPatch $ map (uncurry $ diffTxn j) changed

type Chunk = (GenericSourcePos, [DiffLine String])

-- XXX doctests, update needed:
-- >>> putStr $ renderPatch [(GenericSourcePos "a" 1 1, [D.First "x", D.Second "y"])]
-- --- a
-- +++ a
-- @@ -1,1 +1,1 @@
-- -x
-- +y
-- >>> putStr $ renderPatch [(GenericSourcePos "a" 1 1, [D.Both "x" "x", D.Second "y"]), (GenericSourcePos "a" 5 1, [D.Second "z"])]
-- --- a
-- +++ a
-- @@ -1,1 +1,2 @@
--  x
-- +y
-- @@ -5,0 +6,1 @@
-- +z
-- >>> putStr $ renderPatch [(GenericSourcePos "a" 1 1, [D.Both "x" "x", D.Second "y"]), (GenericSourcePos "b" 5 1, [D.Second "z"])]
-- --- a
-- +++ a
-- @@ -1,1 +1,2 @@
--  x
-- +y
-- --- b
-- +++ b
-- @@ -5,0 +5,1 @@
-- +z
-- | Render list of changed lines as a unified diff
renderPatch :: [Chunk] -> String
renderPatch = go Nothing . sortOn fst where
    go _ [] = ""
    go Nothing cs@((sourceFilePath -> fp, _):_) = fileHeader fp ++ go (Just (fp, 0)) cs
    go (Just (fp, _)) cs@((sourceFilePath -> fp', _):_) | fp /= fp' = go Nothing cs
    go (Just (fp, offs)) ((sourceFirstLine -> lineno, diffs):cs) = chunkHeader ++ chunk ++ go (Just (fp, offs + adds - dels)) cs
        where
            chunkHeader = printf "@@ -%d,%d +%d,%d @@\n" lineno dels (lineno+offs) adds where
            (dels, adds) = foldl' countDiff (0, 0) diffs
            chunk = concatMap renderLine diffs
    fileHeader fp = printf "--- %s\n+++ %s\n" fp fp

    countDiff (dels, adds) = \case
        Del _  -> (dels + 1, adds)
        Add _ -> (dels    , adds + 1)
        Ctx _ -> (dels + 1, adds + 1)

    renderLine = \case
        Del s -> '-' : s ++ "\n"
        Add s -> '+' : s ++ "\n"
        Ctx s -> ' ' : s ++ "\n"

diffTxn :: Journal -> Transaction -> Transaction -> Chunk
diffTxn j t t' =
        case tsourcepos t of
            GenericSourcePos fp lineno _ -> (GenericSourcePos fp (lineno+1) 1, diffs) where
                -- TODO: use range and produce two chunks: one removes part of
                --       original file, other adds transaction to new file with
                --       suffix .ledger (generated). I.e. move transaction from one file to another.
                diffs :: [DiffLine String]
                diffs = concat . map (traverse showPostingLines . mapDiff) $ D.getDiff (tpostings t) (tpostings t')
            pos@(JournalSourcePos fp (line, line')) -> (pos, diffs) where
                -- We do diff for original lines vs generated ones. Often leads
                -- to big diff because of re-format effect.
                diffs :: [DiffLine String]
                diffs = map mapDiff $ D.getDiff source changed'
                source | Just contents <- lookup fp $ jfiles j = map T.unpack . drop (line-1) . take line' $ T.lines contents
                       | otherwise = []
                changed = lines $ showTransactionUnelided t'
                changed' | null changed = changed
                         | null $ last changed = init changed
                         | otherwise = changed

data DiffLine a = Del a | Add a | Ctx a
    deriving (Show, Functor, Foldable, Traversable)

mapDiff :: D.Diff a -> DiffLine a
mapDiff = \case
    D.First x -> Del x
    D.Second x -> Add x
    D.Both x _ -> Ctx x
