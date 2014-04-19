module Propellor.Property.Dns (
	module Propellor.Types.Dns,
	primary,
	secondary,
	secondaryFor,
	mkSOA,
	rootAddressesFrom,
	writeZoneFile,
	nextSerialNumber,
	adjustSerialNumber,
	serialNumberOffset,
	genZone,
) where

import Propellor
import Propellor.Types.Dns
import Propellor.Property.File
import Propellor.Types.Attr
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.Service as Service
import Utility.Applicative

import qualified Data.Map as M
import qualified Data.Set as S
import Data.List

-- | Primary dns server for a domain.
--
-- Most of the content of the zone file is configured by setting properties
-- of hosts. For example,
--
-- > host "foo.example.com"
-- >   & ipv4 "192.168.1.1"
-- >   & alias "mail.exmaple.com"
--
-- Will cause that hostmame and its alias to appear in the zone file,
-- with the configured IP address.
--
-- The [(Domain, Record)] list can be used for additional records
-- that cannot be configured elsewhere. For example, it might contain
-- CNAMEs pointing at hosts that propellor does not control.
primary :: [Host] -> Domain -> SOA -> [(BindDomain, Record)] -> Property
primary hosts domain soa rs = withwarnings (check needupdate baseprop)
	`requires` servingZones
	`onChange` Service.reloaded "bind9"
  where
	(partialzone, warnings) = genZone hosts domain soa
	zone = partialzone { zHosts = zHosts partialzone ++ rs }
	zonefile = "/etc/bind/propellor/db." ++ domain
	baseprop = Property ("dns primary for " ++ domain)
		(makeChange $ writeZoneFile zone zonefile)
		(addNamedConf conf)
	withwarnings p = adjustProperty p $ \satisfy -> do
		mapM_ warningMessage warnings
		satisfy
	conf = NamedConf
		{ confDomain = domain
		, confType = Master
		, confFile = zonefile
		, confMasters = []
		, confLines = []
		}
	needupdate = do
		v <- readZonePropellorFile zonefile
		return $ case v of
			Nothing -> True
			Just oldzone ->
				-- compare everything except serial
				let oldserial = sSerial (zSOA oldzone)
				    z = zone { zSOA = (zSOA zone) { sSerial = oldserial } }
				in z /= oldzone || oldserial < sSerial (zSOA zone)

-- | Secondary dns server for a domain.
--
-- The primary server is determined by looking at the properties of other
-- hosts to find which one is configured as the primary.
--
-- Note that if a host is declared to be a primary and a secondary dns
-- server for the same domain, the primary server config always wins.
secondary :: [Host] -> Domain -> Property
secondary hosts domain = secondaryFor masters hosts domain
  where
	masters = M.keys $ M.filter ismaster $ hostAttrMap hosts
	ismaster attr = case M.lookup domain (_namedconf attr) of
		Nothing -> False
		Just conf -> confType conf == Master && confDomain conf == domain

-- | This variant is useful if the primary server does not have its DNS
-- configured via propellor.
secondaryFor :: [HostName] -> [Host] -> Domain -> -> Property
secondaryFor masters hosts domain = pureAttrProperty desc (addNamedConf conf)
	`requires` servingZones
  where
 	desc = "dns secondary for " ++ domain
	conf = NamedConf
		{ confDomain = domain
		, confType = Secondary
		, confFile = "db." ++ domain
		, confMasters = concatMap (\m -> hostAddresses m hosts) masters
		, confLines = ["allow-transfer { }"]
		}

-- | Rewrites the whole named.conf.local file to serve the zones
-- configured by `primary` and `secondary`, and ensures that bind9 is
-- running.
servingZones :: Property
servingZones = property "serving configured dns zones" go
	`requires` Apt.serviceInstalledRunning "bind9"
	`onChange` Service.reloaded "bind9"
  where
	go = do
		zs <- getNamedConf
		ensureProperty $
			hasContent namedConfFile $
				concatMap confStanza $ M.elems zs

confStanza :: NamedConf -> [Line]
confStanza c =
	[ "// automatically generated by propellor"
	, "zone \"" ++ confDomain c ++ "\" {"
	, cfgline "type" (if confType c == Master then "master" else "slave")
	, cfgline "file" ("\"" ++ confFile c ++ "\"")
	] ++
	(if null (confMasters c) then [] else mastersblock) ++
	(map (\l -> "\t" ++ l ++ ";") (confLines c)) ++
	[ "};"
	, ""
	]
  where
	cfgline f v = "\t" ++ f ++ " " ++ v ++ ";"
	mastersblock =
		[ "\tmasters {" ] ++
		(map (\ip -> "\t\t" ++ fromIPAddr ip ++ ";") (confMasters c)) ++
		[ "\t};" ]

namedConfFile :: FilePath
namedConfFile = "/etc/bind/named.conf.local"

-- | Generates a SOA with some fairly sane numbers in it.
--
-- The Domain is the domain to use in the SOA record. Typically
-- something like ns1.example.com. So, not the domain that this is the SOA
-- record for.
--
-- The SerialNumber can be whatever serial number was used by the domain
-- before propellor started managing it. Or 0 if the domain has only ever
-- been managed by propellor.
--
-- You do not need to increment the SerialNumber when making changes!
-- Propellor will automatically add the number of commits in the git
-- repository to the SerialNumber.
--
-- Handy trick: You don't need to list IPAddrs in the [Record],
-- just make some Host sets its `alias` to the root of domain.
mkSOA :: Domain -> SerialNumber -> [Record] -> SOA
mkSOA d sn rs = SOA
	{ sDomain = AbsDomain d
	, sSerial = sn
	, sRefresh = hours 4
	, sRetry = hours 1
	, sExpire = 2419200 -- 4 weeks
	, sNegativeCacheTTL = hours 8
	, sRecord = rs
	}
  where
	hours n = n * 60 * 60

rootAddressesFrom :: [Host] -> HostName -> [Record]
rootAddressesFrom hosts hn = map Address (hostAddresses hn hosts)

dValue :: BindDomain -> String
dValue (RelDomain d) = d
dValue (AbsDomain d) = d ++ "."
dValue (SOADomain) = "@"

rField :: Record -> String
rField (Address (IPv4 _)) = "A"
rField (Address (IPv6 _)) = "AAAA"
rField (CNAME _) = "CNAME"
rField (MX _ _) = "MX"
rField (NS _) = "NS"
rField (TXT _) = "TXT"
rField (SRV _ _ _ _) = "SRV"

rValue :: Record -> String
rValue (Address (IPv4 addr)) = addr
rValue (Address (IPv6 addr)) = addr
rValue (CNAME d) = dValue d
rValue (MX pri d) = show pri ++ " " ++ dValue d
rValue (NS d) = dValue d
rValue (SRV priority weight port target) = unwords
	[ show priority
	, show weight
	, show port
	, dValue target
	]
rValue (TXT s) = [q] ++ filter (/= q) s ++ [q]
  where
	q = '"'

-- | Adjusts the serial number of the zone to 
--
-- * Always be larger than the serial number in the Zone record.
-- * Always be larger than the passed SerialNumber
nextSerialNumber :: Zone -> SerialNumber -> Zone
nextSerialNumber z serial = adjustSerialNumber z $ \sn -> succ $ max sn serial

adjustSerialNumber :: Zone -> (SerialNumber -> SerialNumber) -> Zone
adjustSerialNumber (Zone d soa l) f = Zone d soa' l
  where
	soa' = soa { sSerial = f (sSerial soa) }

-- | Count the number of git commits made to the current branch.
serialNumberOffset :: IO SerialNumber
serialNumberOffset = fromIntegral . length . lines
	<$> readProcess "git" ["log", "--pretty=%H"]

-- | Write a Zone out to a to a file.
--
-- The serial number in the Zone automatically has the serialNumberOffset
-- added to it. Also, just in case, the old serial number used in the zone
-- file is checked, and if it is somehow larger, its succ is used.
writeZoneFile :: Zone -> FilePath -> IO ()
writeZoneFile z f = do
	oldserial <- oldZoneFileSerialNumber f
	offset <- serialNumberOffset
	let z' = nextSerialNumber
		(adjustSerialNumber z (+ offset))
		oldserial
	createDirectoryIfMissing True (takeDirectory f)
	writeFile f (genZoneFile z')
	writeZonePropellorFile f z'

-- | Next to the zone file, is a ".propellor" file, which contains
-- the serialized Zone. This saves the bother of parsing
-- the horrible bind zone file format.
zonePropellorFile :: FilePath -> FilePath
zonePropellorFile f = f ++ ".propellor"

oldZoneFileSerialNumber :: FilePath -> IO SerialNumber
oldZoneFileSerialNumber = maybe 0 (sSerial . zSOA) <$$> readZonePropellorFile

writeZonePropellorFile :: FilePath -> Zone -> IO ()
writeZonePropellorFile f z = writeFile (zonePropellorFile f) (show z)

readZonePropellorFile :: FilePath -> IO (Maybe Zone)
readZonePropellorFile f = catchDefaultIO Nothing $
	readish <$> readFile (zonePropellorFile f)

-- | Generating a zone file.
genZoneFile :: Zone -> String
genZoneFile (Zone zdomain soa rs) = unlines $
	header : genSOA zdomain soa ++ map genr rs
  where
	header = com $ "BIND zone file for " ++ zdomain ++ ". Generated by propellor, do not edit."

	genr (d, r) = genRecord zdomain (Just d, r)

genRecord :: Domain -> (Maybe BindDomain, Record) -> String
genRecord zdomain (mdomain, record) = intercalate "\t"
	[ hn
	, "IN"
	, rField record
	, rValue record
	]
  where
	hn = maybe "" (domainHost zdomain) mdomain

genSOA :: Domain -> SOA -> [String]
genSOA zdomain soa =
	header ++ map (genRecord zdomain) (zip (repeat Nothing) (sRecord soa))
  where
	header =
		-- "@ IN SOA ns1.example.com. root ("
		[ intercalate "\t"
			[ dValue SOADomain 
			, "IN"
			, "SOA"
			, dValue (sDomain soa)
			, "root"
			, "("
			]
		, headerline sSerial "Serial"
		, headerline sRefresh "Refresh"
		, headerline sRetry "Retry"
		, headerline sExpire "Expire"
		, headerline sNegativeCacheTTL "Negative Cache TTL"
		, inheader ")"
		]
	headerline r comment = inheader $ show (r soa) ++ "\t\t" ++ com comment
	inheader l = "\t\t\t" ++ l

-- | Comment line in a zone file.
com :: String -> String
com s = "; " ++ s

type WarningMessage = String

-- | Generates a Zone for a particular Domain from the DNS properies of all
-- hosts that propellor knows about that are in that Domain.
genZone :: [Host] -> Domain -> SOA -> (Zone, [WarningMessage])
genZone hosts zdomain soa =
	let (warnings, zhosts) = partitionEithers $ concat $ map concat
		[ map hostips inzdomain
		, map hostrecords inzdomain
		, map addcnames (M.elems m)
		]
	in (Zone zdomain soa (nub zhosts), warnings)
  where
	m = hostAttrMap hosts
	-- Known hosts with hostname located in the zone's domain.
	inzdomain = M.elems $ M.filterWithKey (\hn _ -> inDomain zdomain $ AbsDomain $ hn) m
	
	-- Each host with a hostname located in the zdomain
	-- should have 1 or more IPAddrs in its Attr.
	--
	-- If a host lacks any IPAddr, it's probably a misconfiguration,
	-- so warn.
	hostips :: Attr -> [Either WarningMessage (BindDomain, Record)]
	hostips attr
		| null l = [Left $ "no IP address defined for host " ++ _hostname attr]
		| otherwise = map Right l
	  where
		l = zip (repeat $ AbsDomain $ _hostname attr)
			(map Address $ getAddresses attr)

	-- Any host, whether its hostname is in the zdomain or not,
	-- may have cnames which are in the zdomain. The cname may even be
	-- the same as the root of the zdomain, which is a nice way to
	-- specify IP addresses for a SOA record.
	--
	-- Add Records for those.. But not actually, usually, cnames!
	-- Why not? Well, using cnames doesn't allow doing some things,
	-- including MX and round robin DNS, and certianly CNAMES
	-- shouldn't be used in SOA records.
	--
	-- We typically know the host's IPAddrs anyway.
	-- So we can just use the IPAddrs.
	addcnames :: Attr -> [Either WarningMessage (BindDomain, Record)]
	addcnames attr = concatMap gen $ filter (inDomain zdomain) $
		mapMaybe getCNAME $ S.toList (_dns attr)
	  where
		gen c = case getAddresses attr of
			[] -> [ret (CNAME c)]
			l -> map (ret . Address) l
		  where
		  	ret record = Right (c, record)
	
	-- Adds any other DNS records for a host located in the zdomain.
	hostrecords :: Attr -> [Either WarningMessage (BindDomain, Record)]
	hostrecords attr = map Right l
	  where
		l = zip (repeat $ AbsDomain $ _hostname attr)
			(S.toList $ S.filter (\r -> isNothing (getIPAddr r) && isNothing (getCNAME r)) (_dns attr))

inDomain :: Domain -> BindDomain -> Bool
inDomain domain (AbsDomain d) = domain == d || ('.':domain) `isSuffixOf` d
inDomain _ _ = False -- can't tell, so assume not

-- | Gets the hostname of the second domain, relative to the first domain,
-- suitable for using in a zone file.
domainHost :: Domain -> BindDomain -> String
domainHost _ (RelDomain d) = d
domainHost _ SOADomain = "@"
domainHost base (AbsDomain d)
	| dotbase `isSuffixOf` d = take (length d - length dotbase) d
	| base == d = "@"
	| otherwise = d
  where
	dotbase = '.':base

