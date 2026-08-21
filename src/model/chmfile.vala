// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using ChmLib;
using GLib;
using Gee;

namespace Vchm.Model {

    // Helper functions for reading integers from byte arrays (little-endian)
    static uint32 UINT32_FROM_ARRAY (uint8[] array, int offset) {
        return (uint32) array[offset] | ((uint32) array[offset + 1] << 8) | 
               ((uint32) array[offset + 2] << 16) | ((uint32) array[offset + 3] << 24);
    }
    
    static uint16 UINT16_FROM_ARRAY (uint8[] array, int offset) {
        return (uint16) array[offset] | ((uint16) array[offset + 1] << 8);
    }
    
    static ulong be_encint (uint8[] buffer, int index, out int length) {
        ulong result = 0;
        int shift = 0;
        while (true) {
            result |= (ulong)(buffer[index] & 0x7f) << shift;
            if ((buffer[index] & 0x80) == 0) break;
            index++;
            shift += 7;
        }
        length = shift / 7 + 1;
        return result;
    }
    
    static int ffus (uint8[] byte_arr, int bit, out int length) {
        int i = bit / 8;
        int j = bit % 8;
        int b = (byte_arr[i] >> j) & 0x0f;
        int bit_count = 4;
        int num_bits = 0;
        while (b == 0xf) {
            i++;
            b = (byte_arr[i] >> j) & 0x0f;
            bit_count += 4;
            num_bits++;
        }
        length = num_bits * 8 + bit_count;
        return b;
    }
    
    static ulong sr_int (uint8[] buffer, int bit, uint8 s, uint8 r, out int length) {
        int i = bit / 8;
        int j = bit % 8;
        ulong result = 0;
        int shift = 0;
        int b = (buffer[i] >> j) & 0x0f;
        int bit_count = 4;
        while (b == 0xf) {
            i++;
            b = (buffer[i] >> j) & 0x0f;
            bit_count += 4;
        }
        result = b;
        while (true) {
            i++;
            b = (buffer[i] >> j) & 0x0f;
            if (b == 0xf) {
                bit_count += 4;
                continue;
            }
            result = (result << 4) | b;
            bit_count += 4;
            if (bit_count >= s + r) break;
        }
        length = bit_count - 4;
        return result;
    }

    // Result object for content resolution
    public class CHMContent : Object {
        public string content { get; set; }
        public string mime_type { get; set; }
        public string url { get; set; }
        public bool success { get; set; }
        public string error { get; set; }

        public CHMContent () {
            success = false;
        }

        public static CHMContent success_result (string content, string mime_type, string url) {
            var r = new CHMContent ();
            r.success = true;
            r.content = content;
            r.mime_type = mime_type;
            r.url = url;
            return r;
        }

        public static CHMContent error_result (string error) {
            var r = new CHMContent ();
            r.success = false;
            r.error = error;
            return r;
        }
    }

    public class CHMFile : Object {
        private ChmLib.File* _file = null;
        private string _filename = "";
        private string? _first_topic_url = null;
        
        public string filename () {
            return _filename;
        }
        
        public string title () {
            if (_file == null) return "";
            
            ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct();
            if (chm_resolve_object (_file, "/#SYSTEM", out ui) == ChmLib.RESOLVE_SUCCESS) {
                var buffer = new uint8[(int)ui.length];
                if (chm_retrieve_object (_file, &ui, buffer, 0, (long)ui.length) > 0) {
                    string data = (string) buffer;
                    int pos = data.index_of ("Title=");
                    if (pos >= 0) {
                        pos += 6;
                        int end = data.index_of ("\n", pos);
                        if (end < 0) end = data.length;
                        return data.substring (pos, end - pos);
                    }
                }
            }
            return "";
        }
        
        public string home_page () {
            if (_file == null) return "/";
            
            ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct();
            if (chm_resolve_object (_file, "/#SYSTEM", out ui) == ChmLib.RESOLVE_SUCCESS) {
                var buffer = new uint8[(int)ui.length];
                if (chm_retrieve_object (_file, &ui, buffer, 0, (long)ui.length) > 0) {
                    string data = (string) buffer;
                    int pos = data.index_of ("Home=");
                    if (pos >= 0) {
                        pos += 5;
                        int end = data.index_of ("\n", pos);
                        if (end < 0) end = data.length;
                        return data.substring (pos, end - pos);
                    }
                }
            }
            return "/";
        }
        
        public string get_first_topic_url () {
            return _first_topic_url ?? "/";
        }
        
        public bool load (string filename) {
            close ();
            
            if (!GLib.FileUtils.test (filename, GLib.FileTest.EXISTS)) {
                stderr.printf ("CHM file not found: %s\n", filename);
                return false;
            }
            
            _file = chm_open (filename);
            
            if (_file == null) {
                stderr.printf ("Failed to open CHM file: %s\n", filename);
                return false;
            }
            
            _filename = filename;
            return true;
        }
        
        public void close () {
            if (_file != null) {
                chm_close (_file);
                _file = null;
                _filename = "";
                _first_topic_url = null;
            }
        }
        
        // Main public API - resolve a CHM path and get content with MIME type
        public CHMContent get_content (string path) {
            var result = CHMContent.error_result ("Not found");
            
            if (_file == null) {
                result.error = "No CHM file loaded";
                return result;
            }

            // Normalize path
            string norm_path = normalize_path (path);
            
            ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct();
            if (chm_resolve_object (_file, norm_path, out ui) == ChmLib.RESOLVE_SUCCESS) {
                var buffer = new uint8[(int)ui.length];
                long read = chm_retrieve_object (_file, &ui, buffer, 0, (long)ui.length);
                if (read > 0) {
                    // Determine MIME type from extension
                    string mime = get_mime_type (norm_path);
                    
                    // Try to decode as UTF-8, fallback to CP1252/ISO-8859-1
                    string content = decode_content (buffer, read);
                    
                    return CHMContent.success_result (content, mime, norm_path);
                }
            }
            
            result.error = "Failed to resolve: %s".printf (norm_path);
            return result;
        }

        // Get raw binary data for resources (images, CSS, JS)
        public GLib.Bytes? get_bytes (string path) {
            if (_file == null) return null;

            string norm_path = normalize_path (path);
            
            ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct();
            if (chm_resolve_object (_file, norm_path, out ui) == ChmLib.RESOLVE_SUCCESS) {
                var buffer = new uint8[(int)ui.length];
                long read = chm_retrieve_object (_file, &ui, buffer, 0, (long)ui.length);
                if (read > 0) {
                    return new GLib.Bytes (buffer);
                }
            }
            return null;
        }

        // Check if a path exists in the CHM
        public bool has_object (string path) {
            if (_file == null) return false;
            string norm_path = normalize_path (path);
            ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct();
            return chm_resolve_object (_file, norm_path, out ui) == ChmLib.RESOLVE_SUCCESS;
        }

        public bool load_topics_tree (out Object model) {
            ChmLib.UnitInfoStruct ti_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct ts_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct st_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct ut_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct us_ui = ChmLib.UnitInfoStruct();
            
            int ti_res = chm_resolve_object (_file, "/#TOCIDX", out ti_ui);
            int ts_res = chm_resolve_object (_file, "/#TOPICS", out ts_ui);
            int st_res = chm_resolve_object (_file, "/#STRINGS", out st_ui);
            int ut_res = chm_resolve_object (_file, "/#URLTBL", out ut_ui);
            int us_res = chm_resolve_object (_file, "/#URLSTR", out us_ui);
            
            if (_file == null ||
                ts_res != ChmLib.RESOLVE_SUCCESS ||
                st_res != ChmLib.RESOLVE_SUCCESS ||
                ut_res != ChmLib.RESOLVE_SUCCESS ||
                us_res != ChmLib.RESOLVE_SUCCESS) {
                model = null;
                return false;
            }
            
            // Read required data
            var topics = new uint8[(int)ts_ui.length];
            var strings = new uint8[(int)st_ui.length];
            var urltbl = new uint8[(int)ut_ui.length];
            var urlstr = new uint8[(int)us_ui.length];
            
            if (chm_retrieve_object (_file, &ts_ui, topics, 0, (long)ts_ui.length) != (long)ts_ui.length ||
                chm_retrieve_object (_file, &st_ui, strings, 0, (long)st_ui.length) != (long)st_ui.length ||
                chm_retrieve_object (_file, &ut_ui, urltbl, 0, (long)ut_ui.length) != (long)ut_ui.length ||
                chm_retrieve_object (_file, &us_ui, urlstr, 0, (long)us_ui.length) != (long)us_ui.length) {
                model = null;
                return false;
            }
            
            string? first_url = null;
            
            // If TOCIDX exists, use binary TOC tree
            if (ti_res == ChmLib.RESOLVE_SUCCESS && ti_ui.length >= 4) {
                var topidx = new uint8[(int)ti_ui.length];
                if (chm_retrieve_object (_file, &ti_ui, topidx, 0, (long)ti_ui.length) == (long)ti_ui.length) {
                    first_url = parse_binary_toc_first_url (topidx, topics, strings, urltbl, urlstr);
                }
            }
            
            // Fallback: parse #TOPICS sequentially
            if (first_url == null) {
                first_url = parse_topics_sequential_first_url (topics, strings, urltbl, urlstr);
            }
            
            if (first_url != null) {
                _first_topic_url = first_url;
            }
            
            model = null; // Tree building is done in TopicsModel
            return true;
        }
        
        // Provide raw data for TopicsModel to build the tree
        public bool get_topics_data (out uint8[] topics, out uint8[] strings, out uint8[] urltbl, out uint8[] urlstr, out uint8[]? topidx) {
            topics = new uint8[0];
            strings = new uint8[0];
            urltbl = new uint8[0];
            urlstr = new uint8[0];
            topidx = null;
            
            ChmLib.UnitInfoStruct ti_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct ts_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct st_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct ut_ui = ChmLib.UnitInfoStruct();
            ChmLib.UnitInfoStruct us_ui = ChmLib.UnitInfoStruct();
            
            int ti_res = chm_resolve_object (_file, "/#TOCIDX", out ti_ui);
            int ts_res = chm_resolve_object (_file, "/#TOPICS", out ts_ui);
            int st_res = chm_resolve_object (_file, "/#STRINGS", out st_ui);
            int ut_res = chm_resolve_object (_file, "/#URLTBL", out ut_ui);
            int us_res = chm_resolve_object (_file, "/#URLSTR", out us_ui);
            
            if (_file == null ||
                ts_res != ChmLib.RESOLVE_SUCCESS ||
                st_res != ChmLib.RESOLVE_SUCCESS ||
                ut_res != ChmLib.RESOLVE_SUCCESS ||
                us_res != ChmLib.RESOLVE_SUCCESS) {
                return false;
            }
            
            // Read required data
            topics = new uint8[(int)ts_ui.length];
            strings = new uint8[(int)st_ui.length];
            urltbl = new uint8[(int)ut_ui.length];
            urlstr = new uint8[(int)us_ui.length];
            
            if (chm_retrieve_object (_file, &ts_ui, topics, 0, (long)ts_ui.length) != (long)ts_ui.length ||
                chm_retrieve_object (_file, &st_ui, strings, 0, (long)st_ui.length) != (long)st_ui.length ||
                chm_retrieve_object (_file, &ut_ui, urltbl, 0, (long)ut_ui.length) != (long)ut_ui.length ||
                chm_retrieve_object (_file, &us_ui, urlstr, 0, (long)us_ui.length) != (long)us_ui.length) {
                return false;
            }
            
            // Try to read TOCIDX
            topidx = null;
            ChmLib.UnitInfoStruct ti_ui2 = ChmLib.UnitInfoStruct();
            int ti_res2 = chm_resolve_object (_file, "/#TOCIDX", out ti_ui2);
            if (ti_res2 == ChmLib.RESOLVE_SUCCESS && ti_ui2.length >= 4) {
                topidx = new uint8[(int)ti_ui2.length];
                if (chm_retrieve_object (_file, &ti_ui2, topidx, 0, (long)ti_ui2.length) != (long)ti_ui2.length) {
                    topidx = null;
                }
            }
            
            return true;
        }
        
        public bool load_index (out Object model) {
            model = null;
            return false;
        }
        
        public bool load_context_ids () {
            return false;
        }
        
        public bool search (string text, bool whole_words, bool titles_only, out Gee.HashMap<string, string> results) {
            results = new Gee.HashMap<string, string>();
            return false;
        }
        
        public bool is_valid_cid (int context_id) {
            return false;
        }
        
        public string? get_page_by_cid (int context_id) {
            return null;
        }

        private string normalize_path (string path) {
            if (!path.has_prefix ("/")) {
                return "/" + path;
            }
            return path;
        }

        private string decode_content (uint8[] buffer, long length) {
            // Try UTF-8 first
            try {
                var data = buffer[0:(int)length];
                return (string) data;
            } catch {
                // Fallback: treat as ISO-8859-1 / CP1252
                var sb = new StringBuilder ();
                for (int i = 0; i < length; i++) {
                    sb.append_c ((char)buffer[i]);
                }
                return sb.str;
            }
        }

        private string get_mime_type (string path) {
            if (path.has_suffix (".html") || path.has_suffix (".htm"))
                return "text/html";
            else if (path.has_suffix (".css"))
                return "text/css";
            else if (path.has_suffix (".js"))
                return "application/javascript";
            else if (path.has_suffix (".png"))
                return "image/png";
            else if (path.has_suffix (".jpg") || path.has_suffix (".jpeg"))
                return "image/jpeg";
            else if (path.has_suffix (".gif"))
                return "image/gif";
            else if (path.has_suffix (".svg"))
                return "image/svg+xml";
            else if (path.has_suffix (".ico"))
                return "image/x-icon";
            else if (path.has_suffix (".pdf"))
                return "application/pdf";
            else if (path.has_suffix (".txt"))
                return "text/plain";
            else if (path.has_suffix (".xml"))
                return "application/xml";
            else
                return "application/octet-stream";
        }

        private string? parse_binary_toc_first_url (uint8[] topidx, uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr) {
            if (topidx.length < 4) return null;
            
            uint32 root_offset = UINT32_FROM_ARRAY (topidx, 0);
            if (root_offset == 0) return null;
            
            var nodes = new Gee.HashMap<uint32, NodeInfo> ();
            uint32 offset = root_offset;
            while (offset != 0 && offset + 24 <= topidx.length) {
                uint32 flags = UINT32_FROM_ARRAY (topidx, (int)offset + 4);
                uint32 index = UINT32_FROM_ARRAY (topidx, (int)offset + 8);
                uint32 next = UINT32_FROM_ARRAY (topidx, (int)offset + 16);
                uint32 child = UINT32_FROM_ARRAY (topidx, (int)offset + 20);
                
                nodes[offset] = new NodeInfo (offset, flags, index, next, child);
                offset = next;
            }
            
            if (nodes.has_key (root_offset)) {
                return find_first_url_recursive (nodes, root_offset, topics, strings, urltbl, urlstr);
            }
            
            return null;
        }
        
        private string? find_first_url_recursive (Gee.HashMap<uint32, NodeInfo> nodes, uint32 offset, uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr) {
            NodeInfo? node = nodes[offset];
            if (node == null) return null;
            
            string? url = get_item_url (topics, strings, urltbl, urlstr, node.index, (node.flags & 0x8) != 0);
            if (url != null && url != "") {
                return url;
            }
            
            if ((node.flags & 0x4) != 0 && node.child != 0) {
                uint32 child_offset = node.child;
                while (child_offset != 0 && nodes.has_key (child_offset)) {
                    string? child_url = find_first_url_recursive (nodes, child_offset, topics, strings, urltbl, urlstr);
                    if (child_url != null) return child_url;
                    NodeInfo? child_node = nodes[child_offset];
                    if (child_node != null) {
                        child_offset = child_node.next;
                    } else {
                        break;
                    }
                }
            }
            
            if (node.next != 0 && nodes.has_key (node.next)) {
                return find_first_url_recursive (nodes, node.next, topics, strings, urltbl, urlstr);
            }
            
            return null;
        }
        
        private string? parse_topics_sequential_first_url (uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr) {
            int num_entries = topics.length / 16;
            
            for (int i = 0; i < num_entries; i++) {
                int topic_offset = i * 16;
                if (topics.length < topic_offset + 12) break;
                
                uint32 urltbl_offset = UINT32_FROM_ARRAY (topics, topic_offset + 8);
                if (urltbl.length < urltbl_offset + 12) continue;
                
                uint32 urlstr_offset = UINT32_FROM_ARRAY (urltbl, (int)urltbl_offset + 8);
                if (urlstr.length <= urlstr_offset) continue;
                
                int url_start = (int)(urlstr_offset + 8);
                if (urlstr.length <= url_start) continue;
                
                int len = 0;
                while (url_start + len < urlstr.length && urlstr[url_start + len] != 0) len++;
                if (len == 0) continue;
                
                var sb = new StringBuilder ();
                for (int j = 0; j < len; j++) sb.append_c ((char)urlstr[url_start + j]);
                string? url = sb.str;
                
                if (url != null && !url.has_prefix ("/")) {
                    url = "/" + url;
                }
                
                if (url != null && url != "/" && url.length > 1) {
                    return url;
                }
            }
            
            return null;
        }
        
        private string? get_item_name (uint8[] topics, uint8[] strings, uint32 index, bool local) {
            if (local) {
                if (strings.length <= index) return null;
                int len = 0;
                while (index + len < strings.length && strings[index + len] != 0) len++;
                if (len == 0) return null;
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)strings[index + i]);
                return sb.str;
            } else {
                int topic_offset = (int)(index * 16);
                if (topics.length < topic_offset + 4) return null;
                
                uint32 str_offset = UINT32_FROM_ARRAY (topics, topic_offset + 4);
                int32 test = (int32)str_offset;
                if (test == -1) return null;
                if (strings.length <= str_offset) return null;
                
                int len = 0;
                while (str_offset + len < strings.length && strings[str_offset + len] != 0) len++;
                if (len == 0) return null;
                
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)strings[str_offset + i]);
                return sb.str;
            }
        }
        
        private string? get_item_url (uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr, uint32 index, bool local) {
            if (local) {
                if (strings.length <= index) return null;
                int len = 0;
                while (index + len < strings.length && strings[index + len] != 0) len++;
                if (len == 0) return null;
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)strings[index + i]);
                return null;
            } else {
                int topic_offset = (int)(index * 16);
                if (topics.length < topic_offset + 12) return null;
                
                uint32 str_offset = UINT32_FROM_ARRAY (topics, topic_offset + 4);
                int32 test = (int32)str_offset;
                if (test == -1) return null;
                if (strings.length <= str_offset) return null;
                
                uint32 urltbl_offset = UINT32_FROM_ARRAY (topics, topic_offset + 8);
                if (urltbl.length < urltbl_offset + 12) return null;
                
                uint32 urlstr_offset = UINT32_FROM_ARRAY (urltbl, (int)urltbl_offset + 8);
                if (urlstr.length <= urlstr_offset) return null;
                
                int url_start = (int)(urlstr_offset + 8);
                if (urlstr.length <= url_start) return null;
                
                int len = 0;
                while (url_start + len < urlstr.length && urlstr[url_start + len] != 0) len++;
                if (len == 0) return null;
                
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)urlstr[url_start + i]);
                string? url = sb.str;
                
                if (url != null && !url.has_prefix ("/")) {
                    url = "/" + url;
                }
                
                return url;
            }
        }
        
        private class NodeInfo {
            public uint32 offset;
            public uint32 flags;
            public uint32 index;
            public uint32 next;
            public uint32 child;
            
            public NodeInfo (uint32 offset, uint32 flags, uint32 index, uint32 next, uint32 child) {
                this.offset = offset;
                this.flags = flags;
                this.index = index;
                this.next = next;
                this.child = child;
            }
        }
    }
}