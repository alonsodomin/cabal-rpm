{-# LANGUAGE CPP #-}

-- |
-- Module      :  Commands.Spec
-- Copyright   :  (C) 2007-2008  Bryan O'Sullivan
--                (C) 2012-2016  Jens Petersen
--
-- Maintainer  :  Jens Petersen <petersen@fedoraproject.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: Generates an RPM spec file from a .cabal file.

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

module Commands.Spec (
  createSpecFile, createSpecFile_
  ) where

import Dependencies (notInstalled, missingPackages, packageDependencies,
                     showDep, subPackages, testsuiteDependencies)
import Distro (Distro(..), detectDistro)
import Options (RpmFlags (..))
import PackageUtils (copyTarball, getPkgName, latestPackage,
                     nameVersion, PackageData (..), packageName,
                     packageVersion, stripPkgDevel)
import SysCmd ((+-+), notNull)

#if (defined(MIN_VERSION_base) && MIN_VERSION_base(4,8,2))
#else
import Control.Applicative ((<$>))
#endif
import Control.Monad    (filterM, unless, void, when, (>=>))
import Data.Char        (toUpper)
import Data.List        (groupBy, intercalate, intersect, isPrefixOf,
                         nub, sort, (\\))
import Data.Maybe       (fromMaybe, fromJust)
import Data.Time.Clock  (getCurrentTime)
import Data.Time.Format (formatTime)
import qualified Data.Version (showVersion)

import Distribution.License  (License (..)
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(2,2,0)
                             , licenseFromSPDX
#endif
                             )

import Distribution.PackageDescription (BuildInfo (..), PackageDescription (..),
                                        Executable (..),
                                        Library (..), exeName, hasExes, hasLibs,
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(2,2,0)
                                        license,
#endif
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(2,0,0)
                                        unFlagName
#else
                                        FlagName (..)
#endif
                                       )
import Distribution.Simple.Utils (notice, warn)

#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(2,0,0)
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import Distribution.Version (showVersion)
#else
import Data.Version (showVersion)
#endif

--import Distribution.Version (VersionRange, foldVersionRange')

import System.Directory (doesFileExist)
import System.IO     (IOMode (..), hClose, hPutStrLn, openFile)
#if defined(MIN_VERSION_time) && MIN_VERSION_time(1,5,0)
import Data.Time.Format (defaultTimeLocale)
#else
import System.Locale (defaultTimeLocale)
#endif
import System.FilePath (takeBaseName, (</>))

import qualified Paths_cabal_rpm (version)


defaultRelease :: Distro -> String
defaultRelease distro =
    if distro == SUSE then "0" else "1"

rstrip :: (Char -> Bool) -> String -> String
rstrip p = reverse . dropWhile p . reverse

#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(2,0,0)
#else
unFlagName :: FlagName -> String
unFlagName (FlagName n) = n

unUnqualComponentName :: String -> String
unUnqualComponentName = id
#endif

createSpecFile :: PackageData -> RpmFlags ->
                  Maybe FilePath -> IO FilePath
createSpecFile pkgdata flags mdest = do
  let mspec = specFilename pkgdata
      docs = docFilenames pkgdata
      licensefiles = licenseFilenames pkgdata
      pkgDesc = packageDesc pkgdata
      pkg = package pkgDesc
      name = packageName pkg
      verbose = rpmVerbosity flags
      hasExec = hasExes pkgDesc
      hasLib = hasLibs pkgDesc
  (pkgname, binlib) <- getPkgName mspec pkgDesc (rpmBinary flags)
  let pkg_name = if pkgname == name then "%{name}" else "%{pkg_name}"
      basename | binlib = "%{pkg_name}"
               | hasExecPkg = name
               | otherwise = "ghc-%{pkg_name}"
      specFile = fromMaybe "" mdest </> pkgname ++ ".spec"
      hasExecPkg = binlib || (hasExec && not hasLib)
  -- run commands before opening file to prevent empty file on error
  -- maybe shell commands should be in a monad or something
  (deps, tools, clibs, pkgcfgs, selfdep) <- packageDependencies (rpmStrict flags) pkgDesc
  let testsuiteDeps = testsuiteDependencies pkgDesc name
  missTestDeps <- filterM notInstalled testsuiteDeps

  specAlreadyExists <- doesFileExist specFile
  let specFile' = specFile ++ if not (rpmForce flags) && specAlreadyExists then ".cblrpm" else ""
  if specAlreadyExists
    then notice verbose $ specFile +-+ "exists:" +-+ if rpmForce flags then "forcing overwrite" else "creating" +-+ specFile'
    else do
    let realdir dir = "cblrpm." `isPrefixOf` takeBaseName dir
    when (maybe True realdir mdest) $
      putStrLn pkgname

  h <- openFile specFile' WriteMode
  let putHdr hdr val = hPutStrLn h (hdr ++ ":" ++ padding hdr ++ val)
      padding hdr = replicate (14 - length hdr) ' ' ++ " "
      putHdrComment hdr val = putHdr ('#':hdr) (' ':val)
      putNewline = hPutStrLn h ""
      sectionNewline = putNewline >> putNewline
      put = hPutStrLn h
      ghcPkg = if binlib then "-n ghc-%{name}" else ""
      ghcPkgDevel = if binlib then "-n ghc-%{name}-devel" else "devel"

  put $ "# generated by cabal-rpm-" ++ Data.Version.showVersion Paths_cabal_rpm.version
  distro <- fromMaybe detectDistro (return <$> rpmDistribution flags)
  if distro /= SUSE
    then put "# https://fedoraproject.org/wiki/Packaging:Haskell"
    else do
    now <- getCurrentTime
    let year = formatTime defaultTimeLocale "%Y" now
    put "#"
    put $ "# spec file for package " ++ pkgname
    put "#"
    put $ "# Copyright (c) " ++ year ++ " SUSE LINUX GmbH, Nuernberg, Germany."
    put "#"
    put "# All modifications and additions to the file contributed by third parties"
    put "# remain the property of their copyright owners, unless otherwise agreed"
    put "# upon. The license for this file, and modifications and additions to the"
    put "# file, is the same license as for the pristine package itself (unless the"
    put "# license for the pristine package is not an Open Source License, in which"
    put "# case the license is the MIT License). An \"Open Source License\" is a"
    put "# license that conforms to the Open Source Definition (Version 1.9)"
    put "# published by the Open Source Initiative."
    putNewline
    put "# Please submit bugfixes or comments via http://bugs.opensuse.org/"
    put "#"
  putNewline

  -- Some packages conflate the synopsis and description fields.  Ugh.
  let syn = synopsis pkgDesc
  when (null syn) $
    warn verbose "this package has no synopsis."
  let initialCapital (c:cs) = toUpper c:cs
      initialCapital [] = []
  let syn' = if null syn
             then "Haskell" +-+ name +-+ "package"
             else (unwords . lines . initialCapital) syn
  let summary = rstrip (== '.') syn'
  when (length ("Summary     : " ++ syn') > 79) $
    warn verbose "this package has a long synopsis."

  let descr = description pkgDesc
  when (null descr) $
    warn verbose "this package has no description."
  let descLines = (formatParagraphs . initialCapital . filterSymbols . finalPeriod) $ if null descr then syn' else descr
      finalPeriod cs = if last cs == '.' then cs else cs ++ "."
      filterSymbols (c:cs) =
        if c `notElem` "@\\" then c: filterSymbols cs
        else case c of
          '@' -> '\'': filterSymbols cs
          '\\' -> head cs: filterSymbols (tail cs)
          _ -> c: filterSymbols cs
      filterSymbols [] = []
  when hasLib $ do
    put $ "%global pkg_name" +-+ name
    put "%global pkgver %{pkg_name}-%{version}"
    putNewline

  let pkgver = if hasLib then "%{pkgver}" else pkg_name ++ "-%{version}"

  -- FIXME sort by build order
  -- FIXME recursive missingdeps
  missing <- do
    subs <- if rpmSubpackage flags then subPackages (if specAlreadyExists then mspec else Nothing) pkgDesc else return []
    miss <- if rpmSubpackage flags || rpmMissing flags then missingPackages pkgDesc else return []
    return $ nub (subs ++ miss)
  subpkgs <- if rpmSubpackage flags then
    mapM ((getsubpkgMacro flags >=>
           \(m,pv) -> put ("%global" +-+ m +-+ pv) >> return ("%{" ++ m ++ "}"))
           . stripPkgDevel) missing
    else return []
  let hasSubpkgs = notNull subpkgs
  when hasSubpkgs $ do
    put $ "%global subpkgs" +-+ unwords subpkgs
    putNewline

  unless (null testsuiteDeps) $ do
    put $ "%bcond_" ++ (if null missTestDeps then "without" else "with") +-+ "tests"
    putNewline

  let version = packageVersion pkg
      defRelease = defaultRelease distro
      release = fromMaybe defRelease (rpmRelease flags)
      revision = show $ maybe (0::Int) read (lookup "x-revision" (customFieldsPD pkgDesc))
  putHdr "Name" (if binlib then "%{pkg_name}" else basename)
  putHdr "Version" version
  when hasSubpkgs $
    put "# can only be reset when all subpkgs bumped"
  putHdr "Release" $ release ++ (if distro == SUSE then [] else "%{?dist}")
  putHdr "Summary" summary
  case distro of
    SUSE -> putHdr "Group" "Development/Languages/Other"
    RHEL5 -> putHdr "Group" (if binlib then "Development/Languages"
                            else "System Environment/Libraries")
    _ -> return ()
  putNewline
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(2,2,0)
#else
  let licenseFromSPDX = id
#endif
  putHdr "License" $ (showLicense distro . licenseFromSPDX . license) pkgDesc
  putHdr "Url" $ "https://hackage.haskell.org/package" </> pkg_name
  putHdr "Source0" $ sourceUrl pkgver
  mapM_ (\ (n,p) -> putHdr ("Source" ++ n) (sourceUrl p)) $ number subpkgs
  when (revision /= "0") $
    if distro == SUSE
    then putHdr "Source1" $ "https://hackage.haskell.org/package" </> pkgver </> "revision" </> revision ++ ".cabal#" </> pkg_name ++ ".cabal"
    else putStrLn "Warning: this is a revised .cabal file"
  case distro of
    Fedora -> return ()
    _ -> putHdr "BuildRoot" "%{_tmppath}/%{name}-%{version}-build"
  putNewline
  putHdr "BuildRequires" "ghc-Cabal-devel"
  putHdr "BuildRequires" $ "ghc-rpm-macros" ++ (if hasSubpkgs then "-extra" else "")

  let alldeps = sort $ deps ++ tools ++ clibs ++ pkgcfgs
  let extraTestDeps = sort $ testsuiteDeps \\ deps
  unless (null $ alldeps ++ extraTestDeps) $ do
    put "# Begin cabal-rpm deps:"
    mapM_ (\ d -> (if d `elem` missing then putHdrComment else putHdr) "BuildRequires" d) alldeps
    -- for ghc < 7.8
    when (distro `notElem` [Fedora, SUSE] &&
          any (\ d -> d `elem` map showDep ["template-haskell", "hamlet"]) deps) $
      putHdr "ExclusiveArch" "%{ghc_arches_with_ghci}"
    unless (null extraTestDeps) $ do
      put "%if %{with tests}"
      mapM_ (putHdr "BuildRequires") extraTestDeps
      put "%endif"
    put "# End cabal-rpm deps"

  putNewline

  put "%description"
  mapM_ put descLines
  putNewline

  let wrapGenDesc = wordwrap (79 - max 0 (length pkgname - length pkg_name))

  let exposesModules =
        hasLib && (notNull . exposedModules . fromJust . library) pkgDesc

  when hasLib $ do
    when (binlib && exposesModules) $ do
      put $ "%package" +-+ ghcPkg
      putHdr "Summary" $ "Haskell" +-+ pkg_name +-+ "library"
      case distro of
        SUSE -> putHdr "Group" "System/Libraries"
        RHEL5 -> putHdr "Group" "System Environment/Libraries"
        _ -> return ()
      putNewline
      put $ "%description" +-+ ghcPkg
      put $ wrapGenDesc $ "This package provides the Haskell" +-+ pkg_name +-+ "shared library."
      putNewline
    put $ "%package" +-+ ghcPkgDevel
    putHdr "Summary" $ "Haskell" +-+ pkg_name +-+ "library development files"
    case distro of
      RHEL5 -> putHdr "Group" "Development/Libraries"
      SUSE -> putHdr "Group" "Development/Libraries/Other"
      _ -> return ()
    unless (distro == SUSE) $
      putHdr "Provides" $ (if binlib then "ghc-%{name}" else "%{name}") ++ "-static = %{version}-%{release}"
    when exposesModules $
      putHdr "Provides" $ (if binlib then "ghc-%{name}" else "%{name}") ++ "-doc" +-+ "= %{version}-%{release}"
    put "%if %{defined ghc_version}"
    putHdr "Requires" "ghc-compiler = %{ghc_version}"
    putHdr "Requires(post)" "ghc-compiler = %{ghc_version}"
    putHdr "Requires(postun)" "ghc-compiler = %{ghc_version}"
    put "%endif"
    let isa = if distro == SUSE then "" else "%{?_isa}"
    when exposesModules $
      putHdr "Requires" $ (if binlib then "ghc-%{name}" else "%{name}") ++ isa +-+ "= %{version}-%{release}"
    unless (null $ clibs ++ pkgcfgs) $ do
      put "# Begin cabal-rpm deps:"
      mapM_ (putHdr "Requires") $ sort $ map (++ isa) clibs ++ pkgcfgs ++ ["pkgconfig" | distro == SUSE, notNull pkgcfgs]
      put "# End cabal-rpm deps"
    putNewline
    put $ "%description" +-+ ghcPkgDevel
    put $ wrapGenDesc $ "This package provides the Haskell" +-+ pkg_name +-+ "library development files."
    -- previous line ends in an extra newline
    putNewline

  when hasSubpkgs $ do
    put "%global main_version %{version}"
    putNewline
    put "%if %{defined ghclibdir}"
    mapM_ (\p -> put $ "%ghc_lib_subpackage" +-+ p) subpkgs
    put "%endif"
    putNewline
    put "%global version %{main_version}"
    sectionNewline

  put "%prep"
  put $ "%setup -q" ++ (if pkgname /= name then " -n" +-+ pkgver else "") +-+
    (if hasSubpkgs then unwords (map (("-a" ++) . fst) $ number subpkgs) else  "")
  when (distro == SUSE && revision /= "0") $
    put $ "cp -p %{SOURCE1}" +-+ pkg_name ++ ".cabal"
  sectionNewline

  put "%build"
  when hasSubpkgs $
    put "%ghc_libs_build %{subpkgs}"
  when (distro == SUSE && rpmConfigurationsFlags flags /= []) $ do
    let cabalFlags = [ "-f" ++ (if b then "" else "-") ++ unFlagName n | (n, b) <- rpmConfigurationsFlags flags ]
    put $ "%define cabal_configure_options " ++ unwords cabalFlags
  let pkgType = if hasLib then "lib" else "bin"
  if hasLib && not exposesModules
    then put $ "%ghc_" ++ pkgType ++ "_build_without_haddock"
    else put $ "%ghc_" ++ pkgType ++ "_build"
  sectionNewline

  put "%install"
  when hasSubpkgs $
    put "%ghc_libs_install %{subpkgs}"
  put $ "%ghc_" ++ pkgType ++ "_install"

  when selfdep $
    put $ "%ghc_fix_rpath" +-+ pkgver

  let ds = dataFiles pkgDesc
      dupdocs = docs `intersect` ds
      datafiles = ds \\ dupdocs
  unless (null dupdocs) $ do
    putNewline
    putStrLn $ "Warning: doc files found in datadir:" +-+ unwords dupdocs
    unless (distro == SUSE) $
      put $ "rm %{buildroot}%{_datadir}" </> pkgver </>
        case length dupdocs of
           1 -> head dupdocs
           _ -> "{" ++ intercalate "," dupdocs ++ "}"

  when (hasLib && not exposesModules) $
    put "mv %{buildroot}%{_ghcdocdir}{,-devel}"

  when (selfdep && binlib) $
    put "mv %{buildroot}%{_ghclicensedir}/{,ghc-}%{name}"

  sectionNewline

  unless (null testsuiteDeps) $ do
    put "%check"
    put "%cabal_test"
    sectionNewline

  when hasLib $ do
    put $ "%post" +-+ ghcPkgDevel
    put "%ghc_pkg_recache"
    sectionNewline

    put $ "%postun" +-+ ghcPkgDevel
    put "%ghc_pkg_recache"
    sectionNewline

  let license_macro = if distro == Fedora then "%license" else "%doc"
  let execs = sort $ map exeName $ filter isBuildable $ executables pkgDesc

  when hasExecPkg $ do
    put "%files"
    when (distro /= Fedora) $ put "%defattr(-,root,root,-)"
    -- Add the license file to the main package only if it wouldn't
    -- otherwise be empty.
    unless (selfdep && binlib) $
      mapM_ (\ l -> put $ license_macro +-+ l) licensefiles
    unless (null docs) $
      put $ "%doc" +-+ unwords docs
    mapM_ ((\ p -> put $ "%{_bindir}" </> (if p == name then "%{name}" else p)) . unUnqualComponentName) execs
    when (notNull datafiles && not selfdep) $
      put $ "%{_datadir}" </> pkgver

    sectionNewline

  when hasLib $ do
    let baseFiles = if binlib then "-f ghc-%{name}.files" else "-f %{name}.files"
        develFiles = if binlib then "-f ghc-%{name}-devel.files" else "-f %{name}-devel.files"
    when exposesModules $ do
      put $ "%files" +-+ ghcPkg +-+ baseFiles
      when (distro /= Fedora) $ put "%defattr(-,root,root,-)"
      mapM_ (\ l -> put $ license_macro +-+ l) licensefiles
      when (distro == SUSE && not binlib) $
        mapM_ ((\ p -> put $ "%{_bindir}" </> (if p == name then "%{pkg_name}" else p)) . unUnqualComponentName) execs
      when (notNull datafiles && (selfdep  || not binlib)) $
        put $ "%{_datadir}" </> pkgver
      sectionNewline
    put $ "%files" +-+ ghcPkgDevel +-+  develFiles
    when (distro /= Fedora) $ put "%defattr(-,root,root,-)"
    unless exposesModules $
      mapM_ (\ l -> put $ license_macro +-+ l) licensefiles
    unless (null docs) $
      put $ "%doc" +-+ unwords docs
    when (distro /= SUSE && not binlib) $
      mapM_ ((\ p -> put $ "%{_bindir}" </> (if p == name then "%{pkg_name}" else p)) . unUnqualComponentName) execs
    sectionNewline

  put "%changelog"
  unless (distro == SUSE) $ do
    now <- getCurrentTime
    let date = formatTime defaultTimeLocale "%a %b %e %Y" now
    put $ "*" +-+ date +-+ "Fedora Haskell SIG <haskell@lists.fedoraproject.org> - " ++ version ++ "-" ++ release
    put $ "- spec file generated by cabal-rpm-" ++ Data.Version.showVersion Paths_cabal_rpm.version
  hClose h
  return specFile'

createSpecFile_ :: PackageData -> RpmFlags ->
                   Maybe FilePath -> IO ()
createSpecFile_ pkgFiles flags mdest =
  void (createSpecFile pkgFiles flags mdest)

isBuildable :: Executable -> Bool
isBuildable exe = buildable $ buildInfo exe

showLicense :: Distro -> License -> String
showLicense SUSE (GPL Nothing) = "GPL-1.0+"
showLicense _    (GPL Nothing) = "GPL+"
showLicense SUSE (GPL (Just ver)) = "GPL-" ++ showVersion ver ++ "+"
showLicense _    (GPL (Just ver)) = "GPLv" ++ showVersion ver ++ "+"
showLicense SUSE (LGPL Nothing) = "LGPL-2.0+"
showLicense _    (LGPL Nothing) = "LGPLv2+"
showLicense SUSE (LGPL (Just ver)) = "LGPL-" ++ showVersion ver ++ "+"
showLicense _    (LGPL (Just ver)) = "LGPLv" ++ [head $ showVersion ver] ++ "+"
showLicense SUSE BSD3 = "BSD-3-Clause"
showLicense _    BSD3 = "BSD"
showLicense SUSE BSD4 = "BSD-4-Clause"
showLicense _    BSD4 = "BSD"
showLicense _ MIT = "MIT"
showLicense SUSE PublicDomain = "SUSE-Public-Domain"
showLicense _    PublicDomain = "Public Domain"
showLicense SUSE AllRightsReserved = "SUSE-NonFree"
showLicense _    AllRightsReserved = "Proprietary"
showLicense _ OtherLicense = "Unknown"
showLicense _ (UnknownLicense l) = "Unknown" +-+ l
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(1,16,0)
showLicense SUSE (Apache Nothing) = "Apache-2.0"
showLicense _    (Apache Nothing) = "ASL ?"
showLicense SUSE (Apache (Just ver)) = "Apache-" ++ showVersion ver
showLicense _    (Apache (Just ver)) = "ASL" +-+ showVersion ver
#endif
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(1,18,0)
showLicense _ (AGPL Nothing) = "AGPLv?"
showLicense _ (AGPL (Just ver)) = "AGPLv" ++ showVersion ver
#endif
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(1,20,0)
showLicense SUSE BSD2 = "BSD-2-Clause"
showLicense _ BSD2 = "BSD"
showLicense SUSE (MPL ver) = "MPL-" ++ showVersion ver
showLicense _ (MPL ver) = "MPLv" ++ showVersion ver
#endif
#if defined(MIN_VERSION_Cabal) && MIN_VERSION_Cabal(1,22,0)
showLicense _ ISC = "ISC"
showLicense _ UnspecifiedLicense = "Unspecified license!"
#endif

sourceUrl :: String -> String
sourceUrl pv = "https://hackage.haskell.org/package" </> pv </> pv ++ ".tar.gz"

-- http://rosettacode.org/wiki/Word_wrap#Haskell
wordwrap :: Int -> String -> String
wordwrap maxlen = wrap_ 0 False . words
  where
    wrap_ _ _ [] = "\n"
    wrap_ pos eos (w:ws)
      -- at line start: put down the word no matter what
      | pos == 0 = w ++ wrap_ (pos + lw) endp ws
      | pos + lw + 1 > maxlen - 9 && eos = '\n':wrap_ 0 endp (w:ws)
      | pos + lw + 1 > maxlen = '\n':wrap_ 0 endp (w:ws)
      | otherwise = " " ++ w ++ wrap_ (pos + lw + 1) endp ws
      where
        lw = length w
        endp = last w == '.'

formatParagraphs :: String -> [String]
formatParagraphs = map (wordwrap 79) . paragraphs . lines
  where
    -- from http://stackoverflow.com/questions/930675/functional-paragraphs
    -- using split would be: map unlines . (Data.List.Split.splitWhen null)
    paragraphs :: [String] -> [String]
    paragraphs = map (unlines . filter notNull) . groupBy (const notNull)

getsubpkgMacro :: RpmFlags -> String -> IO (String, String)
getsubpkgMacro flags pkg = do
  let name = filter (/= '-') pkg
  pkgver <- latestPackage (rpmHackage flags) pkg
  let (n,v) = nameVersion pkgver
  copyTarball n v False "."
  return (name, pkgver)

number :: [a] -> [(String,a)]
number = zip (map show [(1::Int)..])
