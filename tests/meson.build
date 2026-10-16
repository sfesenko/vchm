test_deps = [
  dependency('gio-2.0', version: '>= 2.76'),
  dependency('gee-0.8', version: '>= 0.20'),
]

# Binary parser fixtures. Generated at build time from tools/mkfixtures.py
# so a fresh clone works without hand-generated blobs; falls
# back to committed-in-workdir copies when python3 is unavailable.
python3 = find_program('python3', required: false)
if python3.found()
  fixture_names = [
    'basic.chm', 'koi8u.chm', 'big.chm', 'deep.chm', 'malformed.chm',
    'fts.chm', 'btree.chm', 'score.chm', 'chi.chm', 'chi.chi', 'win.chm',
    'flat.chm', 'fts_ff.chm', 'fts_fs.chm', 'fts_big.chm', 'cyc.chm',
    'nonul.chm', 'compressed.chm',
    'dir_cword_overflow.chm', 'dir_trunc.chm', 'dir_badfree.chm',
    'dir_badoff.chm', 'dir_selfcycle.chm',
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
# developer's real dconf untouched.
test_env = [
  'GSETTINGS_SCHEMA_DIR=/nonexistent-vchm-tests',
  'GSETTINGS_BACKEND=memory',
]

# (Render/reopen shell tests take their books as positional args.)
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
)
test('test parsers', test_parsers,
  args: [fixtures_dir],
  env: test_env,
  depends: mkfixtures,
)

test_reopen = executable('test_reopen',
  'test_reopen.vala',
  dependencies: [test_deps, lib_core_dep],
)
test('test reopen', test_reopen,
  env: test_env + ['FIXTURES_DIR=' + fixtures_dir],
  depends: mkfixtures,
)

# Reopen integration test is defined in the root meson.build (needs app_sources).

# test_update requires GTK-dependent models, so it's built with the main executable
# and tested separately

# The display-backed render smoke (test render smoke) is defined in the
# root meson.build — it runs the vchm binary under Xvfb, so it needs
# app_sources and the executable target, which are root-scope only.

test_itsf = executable('test_itsf',
  'test_itsf.vala',
  dependencies: [test_deps, lib_core_dep],
)
test('test itsf', test_itsf,
  env: test_env + ['FIXTURES_DIR=' + fixtures_dir,
                   # Vector files (tests/itsfdata/*.lzx) live in the source
                   # tree; the binary locates them via MESON_SOURCE_ROOT or
                   # by walking up from its own path, which only works when
                   # the build dir sits inside the source tree. Pass the
                   # source root explicitly so out-of-tree builds (Step 4:
                   # /tmp/opencode/vchm-cut) resolve vectors too.
                   'MESON_SOURCE_ROOT=' + meson.project_source_root ()],
  depends: mkfixtures,
  # The corpus parity case decodes every object of every local book twice
  # (sync + async); generous budget for slow machines with a big corpus.
  timeout: 600,
)

# (The differential test vs the deleted C reference lived here; the
# async sync/async parity case in test_itsf.vala now guards the decoder.)