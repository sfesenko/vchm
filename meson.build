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


# Build chmlib as a static library
chmlib_sources = [
  'compat/chm_lib.c',
  'compat/lzx.c',
]

chmlib_lib = static_library('chmlib',
  chmlib_sources,
  include_directories: include_directories('compat'),
  c_args: ['-DENABLE_BUILTIN_CHMLIB'],
)


# Shared library for pure logic (testable without GTK).
# Everything in here must stay GTK-free: no widgets, no Gtk imports.
lib_core_sources = [
  'src/elmish.vala',
  'src/model/messages.vala',
  'src/model/chmlib.vala',
  'src/model/chmfile.vala',
  'src/model/history.vala',
  'src/model/searchresult.vala',
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
  link_with: chmlib_lib,
)

lib_core_dep = declare_dependency(
  link_with: lib_core,
  include_directories: include_directories('.'),
)


config_data = configuration_data()
config_data.set_quoted('LOCALEDIR', join_paths(get_option('prefix'), get_option('localedir')))
config_data.set_quoted('GETTEXT_PACKAGE', meson.project_name())
config_file = configure_file(
    input: 'src/Config.vala.in',
    output: '@BASENAME@',
    configuration: config_data
)

executable(
  meson.project_name(),
  [
    'src/main.vala',
    'src/app-view.vala',
    'src/model/topics.vala',
    'src/model/index.vala',
    'src/model/search.vala',
    'src/model/viewer.vala',
    'src/model/settings.vala',
    'src/model/appmodel.vala',
    'src/app-update.vala',
    'src/view/topics.vala',
    'src/view/index.vala',
    'src/view/search.vala',
    'src/view/viewer.vala',
    'src/view/toolbar.vala',
    'src/view/statusbar.vala',
    'src/view/contextmenu.vala',
    'src/view/view.vala',
    config_file,
  ],
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

subdir('tests')