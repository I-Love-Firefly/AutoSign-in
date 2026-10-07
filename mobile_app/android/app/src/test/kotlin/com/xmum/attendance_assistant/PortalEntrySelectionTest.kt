package com.xmum.attendance_assistant

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PortalEntrySelectionTest {
    @Test fun observedSchoolMetaSelectsAcWithoutFilenameGuessing() {
        assertEquals("/index_1.html", PortalEntrySelection.entryPath("https://srun.xmu.edu.my/index_1.html"))
        assertEquals("1", PortalEntrySelection.acId("""<meta http-equiv="refresh" content="0;url=/srun_portal_pc?ac_id=1&amp;theme=pro">"""))
        assertEquals("2", PortalEntrySelection.acId("""<meta http-equiv="refresh" content="0;url=/srun_portal_phone?ac_id=2">"""))
    }

    @Test fun foreignAndUnsupportedEntryRedirectsAreRejected() {
        for (target in listOf("https://example.com/index_1.html", "http://srun.xmu.edu.my/index_1.html", "https://srun.xmu.edu.my:8800/index_1.html", "/other")) {
            assertThrows(Exception::class.java) { PortalEntrySelection.entryPath(target) }
        }
    }

    @Test fun missingDuplicateOrForeignAcSelectionHasNoDefault() {
        for (target in listOf("/srun_portal_pc", "/srun_portal_pc?ac_id=0", "/srun_portal_pc?ac_id=1&ac_id=2", "https://example.com/srun_portal_pc?ac_id=1", "http://srun.xmu.edu.my/srun_portal_pc?ac_id=1")) {
            assertThrows(Exception::class.java) { PortalEntrySelection.acId("""<meta http-equiv="refresh" content="0;url=$target">""") }
        }
        assertThrows(Exception::class.java) { PortalEntrySelection.acId("<html>Unavailable</html>") }
    }
}
