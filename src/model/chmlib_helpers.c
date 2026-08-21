// Helper functions for chmUnitInfo
#include <string.h>
#include "chm_lib.h"

const char* chm_unit_info_get_path (struct chmUnitInfo* ui) {
    if (ui == NULL) return "";
    return ui->path;
}

void chm_unit_info_set_path (struct chmUnitInfo* ui, const char* path) {
    if (ui == NULL || path == NULL) return;
    strncpy (ui->path, path, 512);
    ui->path[512] = '\0';
}