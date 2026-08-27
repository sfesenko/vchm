test_deps = [
  dependency('gio-2.0', version: '>= 2.76'),
  dependency('gee-0.8', version: '>= 0.20'),
]

# Binary parser fixtures. Generated at build time from tools/mkfixtures.py
# so a fresh clone works without hand-generated blobs (review F25); falls
# back to committed-in-workdir copies when python3 is unavailable.
python3 = find_program('python3', required: false)
if python3.found()
  fixture_names = [
    'basic.chm', 'koi8u.chm', 'big.chm', 'deep.chm', 'malformed.chm',
    'fts.chm', 'btree.chm', 'score.chm', 'chi.chm', 'chi.chi', 'win.chm',
    'flat.chm', 'fts_ff.chm', 'fts_fs.chm', 'fts_big.chm', 'cyc.chm',
    'nonul.chm',
    'book_cp1251.chm', 'book_koi8u.chm',
  ]
  mkfixtures = custom_target('chm-fixtures',
    input: [
      join_paths(meson.project_source_root(), 'tools', 'mkfixtures.py'),
      join_paths(meson.project_source_root(), 'tools', 'mkbook.py'),
    ],
    output: fixture_names,
    command: [python3, '@INPUT0@', meson.current_build_dir()],
    build_by_default: true,
  )
  fixtures_dir = meson.current_build_dir()
else
  fixtures_dir = join_paths(meson.current_source_dir(), 'fixtures')
  mkfixtures = []
endif

# Test env: schema dir keeps GSettings happy, memory backend keeps the
# developer's real dconf untouched (review F15).
test_env = [
  'GSETTINGS_SCHEMA_DIR=/nonexistent-vchm-tests',
  'GSETTINGS_BACKEND=memory',
]

# Optional smoke test against a real book when the developer provides one.
real_book = get_option('test_book')
have_real_book = real_book != ''

test_chmlib = executable('test_chmlib',
  'test_chmlib.vala',
  dependencies: [test_deps, lib_core_dep],
  link_with: chmlib_lib,
)
if have_real_book
  test('test chmlib', test_chmlib, args: [real_book], env: test_env)
else
  test('test chmlib', test_chmlib, args: [
    join_paths(fixtures_dir, 'basic.chm'),
  ], env: test_env, depends: mkfixtures)
endif

test_elmish = executable('test_elmish',
  'test_elmish.vala',
  dependencies: [test_deps, lib_core_dep],
)
test('test elmish core', test_elmish)

# OPEN_FILE serialization (F26 follow-up): exercises the model-side
# try_acquire/release path without spinning up GTK.
test_serial = executable('test_serial',
  'test_serial.vala',
  dependencies: [test_deps, lib_core_dep],
)
test('test open serial', test_serial, env: test_env)

# Parser/model unit tests over generated fixtures (GTK-free).
test_parsers = executable('test_parsers',
  'test_parsers.vala',
  dependencies: [test_deps, lib_core_dep],
  link_with: chmlib_lib,
)
test('test parsers', test_parsers,
  args: [fixtures_dir],
  env: test_env,
  depends: mkfixtures,
)

# test_update requires GTK-dependent models, so it's built with the main executable
# and tested separately

# The display-backed render smoke (test render smoke) is defined in the
# root meson.build — it runs the vchm binary under Xvfb, so it needs
# app_sources and the executable target, which are root-scope only.