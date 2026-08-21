// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

// Test CHM file parsing using chmlib

using ChmLib;
using GLib;
using Vchm.Model;

void test_chm_open (string filename) {
    var file = chm_open (filename);
    if (file == null) {
        stderr.printf ("Failed to open CHM file: %s\n", filename);
        return;
    }
    
    stderr.printf ("Successfully opened CHM file: %s\n", filename);
    
    // Try to resolve #SYSTEM
    ChmLib.UnitInfoStruct ui;
    if (chm_resolve_object (file, "/#SYSTEM", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #SYSTEM: start=%lu, length=%lu\n", ui.start, ui.length);
        
        var buffer = new uint8[(int)ui.length];
        var read = chm_retrieve_object (file, &ui, buffer, 0, (long)ui.length);
        if (read > 0) {
            stderr.printf ("Read %ld bytes from #SYSTEM\n", read);
            var text = (string)buffer;
            stderr.printf ("Content: %s\n", text);
        }
    } else {
        stderr.printf ("Failed to resolve #SYSTEM\n");
    }
    
    // Try to resolve #TOCIDX
    if (chm_resolve_object (file, "/#TOCIDX", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #TOCIDX: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#TOCIDX not found\n");
    }
    
    // Try to resolve #TOPICS
    if (chm_resolve_object (file, "/#TOPICS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #TOPICS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#TOPICS not found\n");
    }
    
    // Try to resolve #STRINGS
    if (chm_resolve_object (file, "/#STRINGS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #STRINGS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#STRINGS not found\n");
    }
    
    // Try to resolve #URLTBL
    if (chm_resolve_object (file, "/#URLTBL", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #URLTBL: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#URLTBL not found\n");
    }
    
    // Try to resolve #URLSTR
    if (chm_resolve_object (file, "/#URLSTR", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #URLSTR: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#URLSTR not found\n");
    }
    
    // Try to resolve #TOCIDX
    if (chm_resolve_object (file, "/#TOCIDX", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #TOCIDX: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#TOCIDX not found\n");
    }
    
    // Try to resolve #TOPICS
    if (chm_resolve_object (file, "/#TOPICS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #TOPICS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#TOPICS not found\n");
    }
    
    // Try to resolve #STRINGS
    if (chm_resolve_object (file, "/#STRINGS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #STRINGS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#STRINGS not found\n");
    }
    
    // Try to resolve #URLTBL
    if (chm_resolve_object (file, "/#URLTBL", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #URLTBL: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#URLTBL not found\n");
    }
    
    // Try to resolve #URLSTR
    if (chm_resolve_object (file, "/#URLSTR", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #URLSTR: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#URLSTR not found\n");
    }
    
    // Try to resolve #WINDOWS
    if (chm_resolve_object (file, "/#WINDOWS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #WINDOWS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#WINDOWS not found\n");
    }
    
    // Try to resolve #STRINGS
    if (chm_resolve_object (file, "/#STRINGS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #STRINGS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#STRINGS not found\n");
    }
    
    // Try to resolve #IVB
    if (chm_resolve_object (file, "/#IVB", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #IVB: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#IVB not found\n");
    }
    
    // Try to resolve #STRINGS
    if (chm_resolve_object (file, "/#STRINGS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        stderr.printf ("Found #STRINGS: start=%lu, length=%lu\n", ui.start, ui.length);
    } else {
        stderr.printf ("#STRINGS not found\n");
    }
    
    chm_close (file);
}

void test_resolve_content (string filename) {
    var file = chm_open (filename);
    if (file == null) {
        stderr.printf ("Failed to open\n");
        return;
    }
    
    ChmLib.UnitInfoStruct ui;
    
    // Try to read #TOPICS to see the structure
    if (chm_resolve_object (file, "/#TOPICS", out ui) == ChmLib.RESOLVE_SUCCESS) {
        var buffer = new uint8[(int)ui.length];
        var read = chm_retrieve_object (file, &ui, buffer, 0, (long)ui.length);
        if (read > 0) {
            stderr.printf ("#TOPICS content (%ld bytes):\n", read);
            // Print as hex dump for analysis
            for (int i = 0; i < int.min ((int)read, 500); i++) {
                stderr.printf ("%02x ", buffer[i]);
                if ((i + 1) % 16 == 0) stderr.printf ("\n");
            }
            stderr.printf ("\n");
        }
    }
    
    // Try to read #URLSTR to see URLs
    if (chm_resolve_object (file, "/#URLSTR", out ui) == ChmLib.RESOLVE_SUCCESS) {
        var buffer = new uint8[(int)ui.length];
        var read = chm_retrieve_object (file, &ui, buffer, 0, (long)ui.length);
        if (read > 0) {
            stderr.printf ("#URLSTR content (%ld bytes):\n", read);
            var content = (string) buffer[0:read];
            // Print first 1000 chars
            stderr.printf ("%s\n", content.substring(0, int.min (1000, content.length)));
        }
    }
    
    chm_close (file);
}

void test_chmfile_class (string filename) {
    var chm = new Vchm.Model.CHMFile ();
    if (chm.load (filename)) {
        stderr.printf ("CHMFile load successful\n");
        stderr.printf ("Title: %s\n", chm.title ());
        stderr.printf ("Home page: %s\n", chm.home_page ());
        stderr.printf ("First topic URL: %s\n", chm.get_first_topic_url ());
    } else {
        stderr.printf ("CHMFile load failed\n");
    }
}

int main (string[] args) {
    if (args.length < 2) {
        stderr.printf ("Usage: %s <chm_file>\n", args[0]);
        return 1;
    }
    
    test_chm_open (args[1]);
    stderr.printf ("\n--- Testing content resolution ---\n");
    test_resolve_content (args[1]);
    stderr.printf ("\n--- Testing CHMFile class ---\n");
    test_chmfile_class (args[1]);
    return 0;
}