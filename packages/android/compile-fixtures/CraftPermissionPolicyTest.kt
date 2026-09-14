package {{PACKAGE_NAME}}

import android.Manifest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class CraftPermissionPolicyTest {
    @Test
    fun foregroundLocationAcceptsEitherAndroidAccuracyGrant() {
        val precise = setOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val approximate = setOf(Manifest.permission.ACCESS_COARSE_LOCATION)

        assertEquals(
            "granted",
            CraftPermissionPolicy.status("location", 35, precise::contains)
        )
        assertEquals(
            "granted",
            CraftPermissionPolicy.status("location", 35, approximate::contains)
        )
        assertEquals(
            "denied",
            CraftPermissionPolicy.status("location", 35, emptySet<String>()::contains)
        )
    }

    @Test
    fun backgroundLocationRequiresForegroundAndBackgroundAccess() {
        val foregroundAndBackground = setOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION
        )

        assertEquals(
            "granted",
            CraftPermissionPolicy.status("locationAlways", 35, foregroundAndBackground::contains)
        )
        assertEquals(
            "denied",
            CraftPermissionPolicy.status(
                "locationAlways",
                35,
                setOf(Manifest.permission.ACCESS_COARSE_LOCATION)::contains
            )
        )
    }

    @Test
    fun platformVersionControlsRuntimeOnlyPermissions() {
        assertEquals(
            "granted",
            CraftPermissionPolicy.status("notifications", 32, emptySet<String>()::contains)
        )
        assertEquals(
            "denied",
            CraftPermissionPolicy.status("notifications", 33, emptySet<String>()::contains)
        )
        assertEquals(
            "undetermined",
            CraftPermissionPolicy.status("unsupported", 35, emptySet<String>()::contains)
        )
    }

    @Test
    fun locationRequestIncludesBothAndroidAccuracyPermissions() {
        assertArrayEquals(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ),
            CraftPermissionPolicy.requiredPermissions("location", 35)
        )
    }
}
