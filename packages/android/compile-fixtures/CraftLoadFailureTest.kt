package {{PACKAGE_NAME}}

import android.webkit.WebViewClient
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CraftLoadFailureTest {
    @Test
    fun onlyConnectivityFailuresUseTheBundledCopy() {
        assertTrue(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_HOST_LOOKUP))
        assertTrue(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_CONNECT))
        assertTrue(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_TIMEOUT))
        assertTrue(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_IO))

        assertFalse(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_FAILED_SSL_HANDSHAKE))
        assertFalse(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_AUTHENTICATION))
        assertFalse(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_UNSUPPORTED_AUTH_SCHEME))
        assertFalse(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_BAD_URL))
        assertFalse(CraftLoadFailure.isUnreachable(WebViewClient.ERROR_UNSAFE_RESOURCE))
    }
}
