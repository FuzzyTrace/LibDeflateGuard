files['.luacheckrc'].global = false
files['*.rockspec'].global = false
self = false
max_line_length	= 120
max_code_line_length = 120
max_string_line_length = 120
max_comment_line_length = 120
files['tests/Test.lua'].global = false
exclude_files = {".release/LibDeflateGuard", "tests/LibCompress"}

stds.wow = {
   read_globals = {"LibStub"}
}
std="max+wow"
