{-# LANGUAGE CPP #-}
import Control.Shell
import Data.Bits
import System.Info (os)
import Control.Monad
import System.Environment (getArgs)
import System.Exit

-- Pass 'deb' to build a deb package, 'tarball' to build a tarball, 'all' to
-- build all supported formats, and 'no-rebuild' to avoid rebuilding stuff,
-- only re-packaging it.
--
-- Packages will end up in ghc-$GHC_MAJOR.$GHC_MINOR. If the directory does
-- not exist, it is created. If the package already exists in that directory,
-- it is overwritten.
main = do
    args <- fixAllArg `fmap` getArgs
    when (null args) $ do
      putStrLn $ "Usage: runghc build-release.hs [no-rebuild] formats\n"
      putStrLn $ "Supported formats: deb, tarball, all\n"
      putStrLn $ "no-rebuild\n  Repackage whatever is already in the " ++
                 "_build directory\n  instead of rebuilding from scratch."
      exitFailure

    res <- shell $ do
      srcdir <- pwd
      isdir <- isDirectory "_build"
      when (isdir && not ("no-rebuild" `elem` args)) $ rmdir "_build"
      mkdir True "_build"

      inDirectory "_build" $ do
        unless ("no-rebuild" `elem` args) $ do
          run_ "git" ["clone", srcdir] ""
        inDirectory "haste-compiler" $ do
          (ver, ghcver) <- if ("no-rebuild" `elem` args)
                             then do
                               getVersions
                             else do
                               vers <- buildPortable
                               bootPortable
                               return vers

          let (major, '.':rest) = break (== '.') ghcver
              (minor, _) = break (== '.') rest
              outdir = ".." </> ".." </> ("ghc-" ++ major ++ "." ++ minor)
          mkdir True outdir

          when ("tarball" `elem` args) $ do
            tar <- buildBinaryTarball ver ghcver
            mv tar (outdir </> tar)

          when ("deb" `elem` args) $ do
            deb <- buildDebianPackage srcdir ver ghcver
            mv (".." </> deb) (outdir </> deb)
    case res of
      Left err -> error $ "FAILED: " ++ err
      _        -> return ()
  where
    fixAllArg args | "all" `elem` args = "deb" : "tarball" : args
                   | otherwise         = args

buildPortable = do
    -- Build compiler
    run_ "cabal" ["configure", "-f", "portable"] ""
    run_ "cabal" ["build"] ""

    -- Strip symbols
    case os of
      "linux" -> do
        run_ "strip" ["-s", "haste-compiler/bin/haste-boot"] ""
        run_ "strip" ["-s", "haste-compiler/bin/haste-pkg"] ""
        run_ "strip" ["-s", "haste-compiler/bin/haste-inst"] ""
        run_ "strip" ["-s", "haste-compiler/bin/hastec"] ""
      "mingw32" -> do
        run_ "strip" ["-s", "haste-compiler\\bin\\haste-boot.exe"] ""
        run_ "strip" ["-s", "haste-compiler\\bin\\haste-pkg.exe"] ""
        run_ "strip" ["-s", "haste-compiler\\bin\\haste-inst.exe"] ""
        run_ "strip" ["-s", "haste-compiler\\bin\\hastec.exe"] ""
      _ -> do
        return ()

    -- Get versions
    getVersions

getVersions = do
    ver <- fmap init $ run "haste-compiler/bin/hastec" ["--version"] ""
    ghcver <- fmap init $ run "ghc" ["--numeric-version"] ""
    return (ver, ghcver)

bootPortable = do
    -- Build libs
    run_ "haste-compiler/bin/haste-boot" ["--force", "--local"] ""

    -- Remove unnecessary binaries
    case os of
      "linux" -> do
        rm "haste-compiler/bin/haste-copy-pkg"
        rm "haste-compiler/bin/haste-install-his"
        rm "haste-compiler/bin/haste-boot"
      "ming32" -> do
        rm "haste-compiler\\bin\\haste-copy-pkg.exe"
        rm "haste-compiler\\bin\\haste-install-his.exe"
        rm "haste-compiler\\bin\\haste-boot.exe"
      _ -> do
        return ()
    run_ "find" ["haste-compiler", "-name", "*.o", "-exec", "rm", "{}", ";"] ""
    run_ "find" ["haste-compiler", "-name", "*.a", "-exec", "rm", "{}", ";"] ""

buildBinaryTarball ver ghcver = do
    -- Get versions and create binary tarball
    run_ "tar" ["-cjf", tarball, "haste-compiler"] ""
    return tarball
  where
    tarball =
      concat ["haste-compiler-",ver,"-ghc-",ghcver,"-",os,"-",arch,".tar.bz2"]

arch = if bits == 64 then "amd64" else "i686"
  where
#if __GLASGOW_HASKELL__ >= 708
    bits = finiteBitSize (0 :: Int)
#else
    bits = bitSize (0 :: Int)
#endif

-- Debian packaging based on https://wiki.debian.org/IntroDebianPackaging.
-- Requires build-essential, devscripts and debhelper.
buildDebianPackage srcdir ver ghcver = do
    run_ "debuild" ["-us", "-uc", "-b"] ""
    return $ "haste-compiler_" ++ ver ++ "-1_" ++ arch ++ ".deb"