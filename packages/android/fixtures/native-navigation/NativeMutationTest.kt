package dev.craft.navigationtest

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class NativeMutationTest {
    private fun batch(revision: Int, operations: String, version: Int = 1, base: Int = revision - 1) =
        JSONObject("""
            {
              "version": $version,
              "batchId": "batch-$revision",
              "baseRevision": $base,
              "revision": $revision,
              "operations": $operations
            }
        """.trimIndent())

    @Test
    fun appliesAllOperationsWithStableOrdering() {
        val document = CraftNativeMutationDocument()
        val result = document.apply(batch(1, """
            [
              {"op":"createNode","id":"root","root":true,"node":{"type":"View"}},
              {"op":"createNode","id":"first","node":{"type":"Text","children":["First"]}},
              {"op":"createNode","id":"second","node":{"type":"Text","props":{"testID":"second","accessibilityLabel":"Before"},"style":{"color":"#ff0000"},"events":{"onLongPress":"held"},"children":["Second"]}},
              {"op":"insertChild","parentId":"root","childId":"first","index":0},
              {"op":"insertChild","parentId":"root","childId":"second","index":1},
              {"op":"moveChild","parentId":"root","childId":"second","index":0},
              {"op":"updateNode","id":"second","patch":{"children":["Updated"],"props":{"accessibilityLabel":"After"},"style":{"fontSize":18},"events":{"onPress":"pressed"}}}
            ]
        """.trimIndent()))
        assertEquals(1, result.revision)
        assertEquals(listOf("root", "second"), result.affectedNodeIds)
        assertEquals(listOf("second"), result.updatedNodeIds)
        assertEquals(true, result.requiresFullRender)
        val rendered = requireNotNull(result.document)
        assertEquals("second", rendered.getJSONArray("children").getJSONObject(0).getString("id"))
        val updated = rendered.getJSONArray("children").getJSONObject(0)
        assertEquals("Updated", updated.getJSONArray("children").getString(0))
        assertEquals("second", updated.getJSONObject("props").getString("testID"))
        assertEquals("After", updated.getJSONObject("props").getString("accessibilityLabel"))
        assertEquals("#ff0000", updated.getJSONObject("style").getString("color"))
        assertEquals(18, updated.getJSONObject("style").getInt("fontSize"))
        assertEquals("held", updated.getJSONObject("events").getString("onLongPress"))
        assertEquals("pressed", updated.getJSONObject("events").getString("onPress"))

        val removed = document.apply(batch(2, """
            [{"op":"removeNode","id":"root"}]
        """.trimIndent()))
        assertNull(removed.document)
    }

    @Test
    fun rejectsWholeBatchWithDeterministicFailure() {
        val document = CraftNativeMutationDocument()
        try {
            document.apply(batch(1, """
                [
                  {"op":"createNode","id":"root","root":true,"node":{"type":"View"}},
                  {"op":"removeNode","id":"missing"}
                ]
            """.trimIndent()))
            fail("batch should have failed")
        }
        catch (error: CraftNativeMutationFailure) {
            assertEquals("UNKNOWN_NODE", error.code)
            assertEquals("node missing does not exist", error.message)
            assertEquals(1, error.operationIndex)
        }
        assertEquals(0, document.revision)

        document.apply(batch(1, """
            [{"op":"createNode","id":"root","root":true,"node":{"type":"View"}}]
        """.trimIndent()))
        try {
            document.apply(batch(2, """
                [{"op":"updateNode","id":"root","patch":{"type":"Text"}}]
            """.trimIndent(), version = 2, base = 1))
            fail("version should have failed")
        }
        catch (error: CraftNativeMutationFailure) {
            assertEquals("UNSUPPORTED_VERSION", error.code)
            assertNull(error.operationIndex)
        }
        assertEquals(1, document.revision)
    }

    @Test
    fun rejectsInvalidTreeShapesWithoutAdvancingRevision() {
        val document = CraftNativeMutationDocument()
        document.apply(batch(1, """
            [{"op":"createNode","id":"root","root":true,"node":{"type":"View"}}]
        """.trimIndent()))

        val orphan = failure(document, batch(2, """
            [{"op":"createNode","id":"orphan","node":{"type":"Text"}}]
        """.trimIndent()))
        assertEquals("INVALID_TREE", orphan.code)
        assertEquals("all nodes must be reachable from the root", orphan.message)
        assertNull(orphan.operationIndex)
        assertEquals(1, document.revision)
        assertNull(document.node("orphan"))

        val nestedRoot = failure(document, batch(2, """
            [
              {"op":"createNode","id":"parent","node":{"type":"View"}},
              {"op":"insertChild","parentId":"parent","childId":"root","index":0}
            ]
        """.trimIndent()))
        assertEquals("INVALID_TREE", nestedRoot.code)
        assertEquals("root node must not have a parent", nestedRoot.message)
        assertEquals(1, document.revision)
        assertNull(document.node("parent"))

        val invalidIndex = failure(document, batch(2, """
            [
              {"op":"createNode","id":"child","node":{"type":"Text"}},
              {"op":"insertChild","parentId":"root","childId":"child","index":2}
            ]
        """.trimIndent()))
        assertEquals("INVALID_INDEX", invalidIndex.code)
        assertEquals(1, invalidIndex.operationIndex)
        assertEquals(1, document.revision)
        assertNull(document.node("child"))

        val stale = failure(document, batch(2, """
            [{"op":"removeNode","id":"root"}]
        """.trimIndent(), base = 0))
        assertEquals("REVISION_MISMATCH", stale.code)
        assertNull(stale.operationIndex)
        assertEquals(1, document.revision)
    }

    private fun failure(
        document: CraftNativeMutationDocument,
        payload: JSONObject
    ): CraftNativeMutationFailure = try {
        document.apply(payload)
        fail("batch should have failed")
        throw AssertionError("unreachable")
    }
    catch (error: CraftNativeMutationFailure) {
        error
    }
}
