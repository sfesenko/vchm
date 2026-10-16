project('itsf', 'vala',
  version: '0.1.0',
  license: 'MIT',
  default_options: ['warning_level=2'],
)

glib_dep = dependency('glib-2.0', version: '>= 2.76')
gio_dep  = dependency('gio-2.0',    version: '>= 2.76')
gee_dep  = dependency('gee-0.8',    version: '>= 0.20')

itsf_sources = [
  'src/error.vala',
  'src/index.vala',
  'src/container.vala',
  'src/archive.vala',
  'src/sections.vala',
  'src/lzx/bitreader.vala',
  'src/lzx/huffman.vala',
  'src/lzx/window.vala',
  'src/lzx/decoder.vala',
]

lib_itsf = static_library('itsf',
  itsf_sources,
  vala_args: ['--target-glib=2.76'],
  dependencies: [glib_dep, gio_dep, gee_dep],
)

itsf_dep = declare_dependency(
  link_with: lib_itsf,
  include_directories: include_directories('.'),
)
