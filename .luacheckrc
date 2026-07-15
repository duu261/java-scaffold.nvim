std = "luajit"
globals = { "vim" }
max_line_length = 100

files["tests/"] = { globals = { "describe", "it", "before_each", "after_each", "assert" } }
