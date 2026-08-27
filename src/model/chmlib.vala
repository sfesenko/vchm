// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

// CHM Library bindings - direct C function declarations

namespace ChmLib {
    // Opaque pointer type
    [CCode (cname = "chmFile", cheader_filename = "chm_lib.h")]
    public struct File {
        public void* _dummy;
    }

    // The raw C struct for interop with C functions
    [CCode (cname = "chmUnitInfo", cheader_filename = "chm_lib.h", has_type_id = false)]
    public struct UnitInfoStruct {
        public ulong start;
        public ulong length;
        public int space;
        public int flags;
        public uint8 path[513];
    }

    // Free functions for CHM operations
    [CCode (cname = "chm_open", cheader_filename = "chm_lib.h", extern = true)]
    public extern File* chm_open (string filename);

    [CCode (cname = "chm_close", cheader_filename = "chm_lib.h", extern = true)]
    public extern void chm_close (File* h);

    [CCode (cname = "chm_set_param", cheader_filename = "chm_lib.h", extern = true)]
    public extern void chm_set_param (File* h, int param_type, int param_val);

    [CCode (cname = "chm_resolve_object", cheader_filename = "chm_lib.h", extern = true)]
    public extern int chm_resolve_object (File* h, string obj_path, out UnitInfoStruct ui);

    [CCode (cname = "chm_retrieve_object", cheader_filename = "chm_lib.h", extern = true)]
    public extern long chm_retrieve_object (File* h, UnitInfoStruct* ui, uint8* buf, ulong addr, long len);

    [CCode (cname = "chm_enumerate", cheader_filename = "chm_lib.h", extern = true)]
    public extern int chm_enumerate (File* h, int what, EnumerateCb cb, void* context);

    // CHM_ENUMERATOR: int (*)(chmFile*, chmUnitInfo*, void*)
    [CCode (has_target = false)]
    public delegate int EnumerateCb (File* h, UnitInfoStruct* ui, void* context);

    // Constants from chm_lib.h
    public const int UNCOMPRESSED = 0;
    public const int COMPRESSED = 1;

    public const int RESOLVE_SUCCESS = 0;
    public const int RESOLVE_FAILURE = 1;

    public const int PARAM_MAX_BLOCKS_CACHED = 0;

    public const int ENUMERATE_NORMAL = 1;
    public const int ENUMERATE_META = 2;
    public const int ENUMERATE_SPECIAL = 4;
    public const int ENUMERATE_FILES = 8;
    public const int ENUMERATE_DIRS = 16;
    public const int ENUMERATE_ALL = 31;

    public const int ENUMERATOR_FAILURE = 0;
    public const int ENUMERATOR_CONTINUE = 1;
    public const int ENUMERATOR_SUCCESS = 2;
}