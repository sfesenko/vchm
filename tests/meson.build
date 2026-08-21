test_deps = [
  dependency('gio-2.0', version: '>= 2.76'),
  dependency('gee-0.8', version: '>= 0.20'),
]

test_chmlib = executable('test_chmlib',
  'test_chmlib.vala',
  dependencies: [test_deps, lib_core_dep],
  link_with: chmlib_lib,
)
test('test chmlib', test_chmlib, args: ['***REMOVED***//Documents/Books/<redacted>.chm'])

test_elmish = executable('test_elmish',
  'test_elmish.vala',
  dependencies: [test_deps, lib_core_dep],
)
test('test elmish core', test_elmish)

# test_update requires GTK-dependent models, so it's built with the main executable
# and tested separately