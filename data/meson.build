desktop_file = i18n.merge_file(
  input: 'org.gnome.vchm.desktop.in',
  output: 'org.gnome.vchm.desktop',
  type: 'desktop',
  po_dir: '../po',
  install: true,
  install_dir: join_paths(get_option('datadir'), 'applications')
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('Validate desktop file', desktop_utils,
    args: [desktop_file]
  )
endif

appstream_file = i18n.merge_file(
  input: 'org.gnome.vchm.appdata.xml.in',
  output: 'org.gnome.vchm.appdata.xml',
  po_dir: '../po',
  install: true,
  install_dir: join_paths(get_option('datadir'), 'metainfo')
)

appstream_util = find_program('appstream-util', required: false)
if appstream_util.found()
  test('Validate appstream file', appstream_util,
    args: ['validate', '--nonet', appstream_file]
  )
endif

# GSettings schema
install_data('org.gnome.vchm.gschema.xml',
  install_dir: join_paths(get_option('datadir'), 'glib-2.0/schemas')
)
gnome.compile_schemas()

subdir('icons')