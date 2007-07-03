module Ledger
where
import qualified Data.Map as Map
import Data.Map ((!))
import Data.Ord (comparing)

import Utils
import Types
import Amount
import Account
import AccountName
import EntryTransaction
import RawLedger


cacheLedger :: RawLedger -> Ledger
cacheLedger l = 
    let 
        ant = trace "caching" $ rawLedgerAccountNameTree l
        ans = flatten ant
        ts = rawLedgerTransactions l
        sortedts = sortBy (comparing account) ts
        groupedts = groupBy (\t1 t2 -> account t1 == account t2) sortedts
        tmap = Map.union 
               (Map.fromList [(account $ head g, g) | g <- groupedts])
               (Map.fromList [(a,[]) | a <- ans])
        bmap = Map.union 
               (Map.fromList [(a, sumEntryTransactions $ transactionsWithOrBelowAccountName a ts) | a <- ans]) 
               (Map.fromList [(a,nullamt) | a <- ans])
        amap = Map.fromList [(a, Account a (tmap ! a) (bmap ! a)) | a <- ans]
    in
      Ledger l ant amap

ledgerAccount :: Ledger -> AccountName -> Account
-- wtf  ledgerAccount l = ((accounts l) (!))
ledgerAccount l aname = head [a | (n,a) <- Map.toList $ accounts l, n == aname]

ledgerTransactions :: Ledger -> [EntryTransaction]
ledgerTransactions l = concatMap atransactions $ Map.elems $ accounts l

ledgerTransactionsMatching :: ([String],[String]) -> Ledger -> [EntryTransaction]
ledgerTransactionsMatching pats l = rawLedgerTransactionsMatching pats $ rawledger l

showLedgerAccounts :: Ledger -> [String] -> Bool -> Int -> String
showLedgerAccounts l acctpats showsubs maxdepth = 
    concatMap 
    (showAccountTree2 l) 
    (branches (ledgerAccountTreeMatching l acctpats showsubs maxdepth))

showAccountTree2 :: Ledger -> Tree Account -> String
showAccountTree2 l = showAccountTree'2 l 0 . interestingAccountsFrom

showAccountTree'2 :: Ledger -> Int -> Tree Account -> String
showAccountTree'2 l indentlevel t
    -- if this acct is boring, don't show it
    | isBoringInnerAccount2 l acct = subacctsindented 0
    -- otherwise show normal indented account name with balance, 
    -- prefixing the names of any boring parents
    | otherwise = 
        bal ++ "  " ++ indent ++ prefix ++ leafname ++ "\n" ++ (subacctsindented 1)
    where
      acct = root t
      subacctsindented i = concatMap (showAccountTree'2 l (indentlevel+i)) $ branches t
      bal = printf "%20s" $ show $ abalance $ acct
      indent = replicate (indentlevel * 2) ' '
      prefix = concatMap (++ ":") $ map accountLeafName boringparents
      boringparents = takeWhile (isBoringInnerAccountName2 l) $ parentAccountNames $ aname acct
      leafname = accountLeafName $ aname acct

isBoringInnerAccount2 :: Ledger -> Account -> Bool
isBoringInnerAccount2 l a
    | name == "top" = False
    | (length txns == 0) && ((length subs) == 1) = True
    | otherwise = False
    where      
      name = aname a
      txns = atransactions a
      subs = subAccountNamesFrom (accountnames l) name

accountnames :: Ledger -> [AccountName]
accountnames l = flatten $ accountnametree l

isBoringInnerAccountName2 :: Ledger -> AccountName -> Bool
isBoringInnerAccountName2 l name
    | name == "top" = False
    | (length txns == 0) && ((length subs) == 1) = True
    | otherwise = False
    where
      txns = atransactions $ ledgerAccount l name
      subs = subAccountNamesFrom (accountnames l) name

transactionsInAccountNamed2 :: Ledger -> AccountName -> [EntryTransaction]
transactionsInAccountNamed2 l a = atransactions $ ledgerAccount l a

----

ledgerAccountTreeMatching :: Ledger -> [String] -> Bool -> Int -> Tree Account
ledgerAccountTreeMatching l [] showsubs maxdepth = 
    ledgerAccountTreeMatching l [".*"] showsubs maxdepth
ledgerAccountTreeMatching l acctpats showsubs maxdepth = 
    addDataToAccountNameTree2 l $ 
    filterAccountNameTree acctpats showsubs maxdepth $ 
    accountnametree l

addDataToAccountNameTree2 :: Ledger -> Tree AccountName -> Tree Account
addDataToAccountNameTree2 l ant = 
    Node 
    (ledgerAccount l $ root ant) 
    (map (addDataToAccountNameTree2 l) $ branches ant)

-- ledgerAccountNames :: Ledger -> [AccountName]
-- ledgerAccountNames = sort . expandAccountNames . rawLedgerAccountNamesUsed

