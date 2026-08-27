project('vchm', ['c', 'vala'],
      version: '0.1.0',
      meson_version: '>= 0.59.0',
      default_options: [ 'warning_level=2',
                         'werror=false',
                       ],
)

# Optional path to a real .chm for the smoke test; empty = use fixtures.
test_book = get_option('test_book')

i18n = import('i18n')

gnome = import('gnome')

add_global_arguments([
        '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
    ],
    language: 'c'
)

subdir('data')
subdir('po')

gnome.post_install(
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)


# Build chmlib as a static library
chmlib_sources = [
  'compat/chm_lib.c',
  'compat/lzx.c',
]

# Vendored chmlib header. Listed
# FIRST on the include path so every consumer — the vendored C sources
# and all Vala-generated code — resolves chm_lib.h to our copy instead
# of a possibly ABI-skewed system one (review F19).
inc_compat = include_directories('compat')

chmlib_lib = static_library('chmlib',
  chmlib_sources,
  include_directories: [inc_compat, include_directories('compat')],
  c_args: ['-DENABLE_BUILTIN_CHMLIB'],
)


# Shared library for pure logic (testable without GTK).
# Everything in here must stay GTK-free: no widgets, no Gtk imports.
lib_core_sources = [
  'src/elmish.vala',
  'src/model/messages.vala',
  'src/model/chmlib.vala',
  'src/model/chmfile.vala',
  'src/model/hhcparser.vala',
  'src/model/htmlutils.vala',
  'src/model/bookmarks.vala',
  'src/model/history.vala',
  'src/model/searchresult.vala',
  'src/model/settings.vala',
  'src/model/viewer.vala',
  'src/model/topics.vala',
  'src/model/index.vala',
  'src/model/search.vala',
  'src/model/appmodel.vala',
]

lib_core = static_library('vchm-core',
  lib_core_sources,
  vala_args: [
    '--target-glib=2.76',
  ],
  dependencies: [
    dependency('gio-2.0', version: '>= 2.76'),
    dependency('gee-0.8', version: '>= 0.20'),
  ],
  c_args: ['-I@CURRENT_SOURCE_DIR@/compat'],
  include_directories: inc_compat,
  link_with: chmlib_lib,
)

lib_core_dep = declare_dependency(
  link_with: lib_core,
  include_directories: [include_directories('.'), inc_compat],
)


config_data = configuration_data()
config_data.set_quoted('VERSION', meson.project_version())
config_data.set_quoted('LOCALEDIR', join_paths(get_option('prefix'), get_option('localedir')))
config_data.set_quoted('GETTEXT_PACKAGE', meson.project_name())
config_file = configure_file(
    input: 'src/Config.vala.in',
    output: '@BASENAME@',
    configuration: config_data
)

app_sources = [
    'src/app-view.vala',
    'src/app-update.vala',
    'src/view/topics.vala',
    'src/view/index.vala',
    'src/view/search.vala',
    'src/view/bookmarks.vala',
    'src/view/viewer.vala',
    'src/view/toolbar.vala',
    'src/view/statusbar.vala',
    'src/view/contextmenu.vala',
    'src/view/view.vala',
]

vchm = executable(
  meson.project_name(),
  [app_sources, 'src/main.vala', config_file],
  vala_args: [
    '--target-glib=2.76',
  ],
  dependencies: [
    dependency('gtk4', version: '>= 4.10'),
    dependency('webkitgtk-6.0', version: '>= 2.40'),
    dependency('gee-0.8', version: '>= 0.20'),
    lib_core_dep,
  ],
  link_with: chmlib_lib,
  install: true,
)

# GTK-side update-function tests (shares app sources, own main).
test_update = executable(
  'test_update',
  [app_sources, 'tests/test_update.vala', config_file],
  vala_args: [
    '--target-glib=2.76',
  ],
  dependencies: [
    dependency('gtk4', version: '>= 4.10'),
    dependency('webkitgtk-6.0', version: '>= 2.40'),
    dependency('gee-0.8', version: '>= 0.20'),
    lib_core_dep,
  ],
  link_with: chmlib_lib,
)
test('test update', test_update,
  env: [
    'GSETTINGS_SCHEMA_DIR=' + join_paths(meson.project_build_root(), 'data'),
    'GSETTINGS_BACKEND=memory',
  ])

# Display-backed render smoke for the view layer, gated behind
# enable_render_test so a headless CI box is never blocked by it. Runs the
# real vchm binary under Xvfb+dbus and asserts the window actually painted
# (see tools/smoke_render.sh). Needs xvfb-run + dbus-launch at run time; a
# missing dependency makes the test SKIP rather than FAIL.
if get_option('enable_render_test')
  smoke_render = join_paths(meson.project_source_root (), 'tools', 'smoke_render.sh')
  render_fixtures = [
    join_paths(meson.current_build_dir (), 'tests', 'basic.chm'),
    join_paths(meson.current_build_dir (), 'tests', 'book_cp1251.chm'),
    join_paths(meson.current_build_dir (), 'tests', 'book_koi8u.chm'),
  ]
  # Optional 4th fixture: a real multi-chapter CP1251 book from the
  # developer's library. Skipped if not present so the test stays
  # hermetic on a fresh checkout.
  arch_book = '***REMOVED***//Documents/Books/<redacted>.chm'
  if run_command('test', '-f', arch_book, check: false).returncode() == 0
    render_fixtures += [arch_book]
  endif
  test('test render smoke', vchm,
    args: [smoke_render, vchm] + render_fixtures,
    env: [
      'GSETTINGS_BACKEND=memory',
    ],
  )
endif

subdir('tests')