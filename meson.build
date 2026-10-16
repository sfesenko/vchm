project('vchm', ['c', 'vala'],
      version: '0.1.0',
      meson_version: '>= 0.59.0',
      default_options: [ 'warning_level=2',
                         'werror=false',
                       ],
)

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


itsf_dep = subproject('itsf').get_variable('itsf_dep')

# Shared library for pure logic (testable without GTK).
# Everything in here must stay GTK-free: no widgets, no Gtk imports.
lib_core_sources = [
  'src/elmish.vala',
  'src/model/messages.vala',
  'src/model/chmfile.vala',
  'src/model/hhcparser.vala',
  'src/model/htmlutils.vala',
  'src/model/bookmarks.vala',
  'src/model/perbook.vala',
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
    itsf_dep,
  ],
  c_args: [],
)

lib_core_dep = declare_dependency(
  link_with: lib_core,
  include_directories: [include_directories('.')],
  dependencies: [itsf_dep],
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
  # book_cp1251.chm above already provides a multi-chapter CP1251 book
  # (Ukrainian pages, image subresource, entities, relative + ../ links),
  # so no developer-local book is needed here and the test stays hermetic.
  test('test render smoke', find_program('bash'),
    args: [smoke_render, vchm] + render_fixtures,
    env: [
      'GSETTINGS_BACKEND=memory',
      # WebKit's bubblewrap sandbox cannot run on a locked-down CI box.
      'WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1',
    ],
    # smoke_render.sh sleeps 12s per fixture (3 fixtures) plus Xvfb startup.
    timeout: 120,
  )
endif

# Reopen integration test (Xvfb, checks Fort blank fix).
# Always registered, but the script itself SKIPs if xvfb/import/Pillow are
# missing, so a headless CI is never blocked. Uses a generated fixture so
# it is hermetic.
reopen_sh = join_paths(meson.project_source_root (), 'tools', 'test_reopen.sh')
test('test reopen shell', find_program('bash'),
  args: [reopen_sh, vchm, join_paths(meson.current_build_dir (), 'tests', 'compressed.chm')],
  env: ['GSETTINGS_BACKEND=memory',
        'WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1'],
  timeout: 30,
)

subdir('tests')