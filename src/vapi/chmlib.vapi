[CCode (cprefix = "chm_", cheader_filename = "chm_lib.h", lower_case_cprefix = "chm_", lower_case_csuffix = "", has_type_id = false)]
namespace ChmLib {
    [CCode (cname = "LONGUINT64")]
    public struct ULong64 {
        public ulong value;
    }

    [CCode (cname = "LONGINT64")]
    public struct Long64 {
        public long value;
    }

    [Compact]
    [CCode (cname = "chmUnitInfo", free_function = "", copy_function = "", has_type_id = false)]
    public struct UnitInfo {
        [CCode (cname = "start")]
        public ULong64 start;
        [CCode (cname = "length")]
        public ULong64 length;
        [CCode (cname = "space")]
        public int space;
        [CCode (cname = "flags")]
        public int flags;
        [CCode (cname = "path")]
        public string path;
    }

    [CCode (cname = "chmFile", free_function = "chm_close", copy_function = "", has_type_id = false)]
    public class File : GLib.Object {
        [CCode (cname = "chm_open")]
        public File (string filename) {
        }

        [CCode (cname = "chm_open")]
        public static File? open (string filename) {
            return null;
        }

        [CCode (cname = "chm_close")]
        public void close () {
        }

        [CCode (cname = "chm_set_param")]
        public void set_param (int param_type, int param_val) {
        }

        [CCode (cname = "chm_resolve_object")]
        public bool resolve_object (string obj_path, out UnitInfo ui) {
            ui = UnitInfo();
            return false;
        }

        [CCode (cname = "chm_retrieve_object")]
        public long retrieve_object (UnitInfo ui, uint8[] buffer, ulong addr, long len) {
            return -1;
        }

        public delegate int Enumerator (File h, UnitInfo ui, void* context);

        [CCode (cname = "chm_enumerate")]
        public int enumerate (int what, Enumerator e, void* context) {
            return 0;
        }

        [CCode (cname = "chm_enumerate_dir")]
        public int enumerate_dir (string prefix, int what, Enumerator e, void* context) {
            return 0;
        }
    }

    public const int UNCOMPRESSED;
    public const int COMPRESSED;

    public const int RESOLVE_SUCCESS;
    public const int RESOLVE_FAILURE;

    public const int PARAM_MAX_BLOCKS_CACHED;

    public const int ENUMERATE_NORMAL;
    public const int ENUMERATE_META;
    public const int ENUMERATE_SPECIAL;
    public const int ENUMERATE_FILES;
    public const int ENUMERATE_DIRS;
    public const int ENUMERATE_ALL;

    public const int ENUMERATOR_FAILURE;
    public const int ENUMERATOR_CONTINUE;
    public const int ENUMERATOR_SUCCESS;
}