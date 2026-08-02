package = "libdeflateguard"
version = "1.1.2-1"
source = {
   url = "git+https://github.com/FuzzyTrace/LibDeflateGuard.git",
   tag = "v1.1.2",
}
description = {
   summary = "Private, hardened LibDeflate-compatible DEFLATE codecs",
   detailed = [[LibDeflateGuard is an independently maintained fork of LibDeflate with bounded, non-throwing decode seams.]],
   homepage = "https://github.com/FuzzyTrace/LibDeflateGuard",
   license = "zlib",
}
dependencies = {
   "lua >= 5.1, < 5.5"
}
build = {
   type = "builtin",
   modules = {
      LibDeflateGuard = "LibDeflateGuard.lua",
   },
   copy_directories = {
      "docs",
      "examples",
   }
}
