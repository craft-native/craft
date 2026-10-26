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
    fun materializesTheCommittedRootWithoutAssumingItsProtocolId() {
        val document = CraftNativeMutationDocument()
        assertNull(document.document())
        document.replace(JSONObject("""{"id":"compiled-root","type":"SafeAreaView"}"""))
        assertEquals("compiled-root", document.document()?.getString("id"))
        document.apply(batch(1, """[{"op":"updateNode","id":"compiled-root","patch":{"props":{"testID":"updated"}}}]"""))
        assertEquals("updated", document.document()?.getJSONObject("props")?.getString("testID"))
        document.apply(batch(2, """[{"op":"removeNode","id":"compiled-root"}]"""))
        assertNull(document.document())
    }

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
    fun preservesAuthoredKeysAcrossImportCreationUpdatesAndMoves() {
        val document = CraftNativeMutationDocument()
        document.replace(JSONObject("""
            {"id":"root","type":"View","key":"root-key","children":[
              {"id":"existing","type":"TextInput","key":"draft-key","props":{"value":"draft"}}
            ]}
        """.trimIndent()))
        assertEquals("draft-key", document.node("existing")?.getString("key"))
        val result = document.apply(batch(1, """
            [
              {"op":"createNode","id":"created","node":{"type":"View","key":"created-key"}},
              {"op":"insertChild","parentId":"root","childId":"created","index":1},
              {"op":"updateNode","id":"existing","patch":{"props":{"value":"edited"}}},
              {"op":"moveChild","parentId":"root","childId":"created","index":0}
            ]
        """.trimIndent()))
        val rendered = requireNotNull(result.document)
        assertEquals("root-key", rendered.getString("key"))
        assertEquals("created-key", rendered.getJSONArray("children").getJSONObject(0).getString("key"))
        assertEquals("draft-key", rendered.getJSONArray("children").getJSONObject(1).getString("key"))
        assertEquals("edited", document.node("existing")?.getJSONObject("props")?.getString("value"))
    }

    @Test
    fun reparentsChildAcrossParentsAtomically() {
        val document = CraftNativeMutationDocument()
        document.apply(batch(1, """
            [
              {"op":"createNode","id":"root","root":true,"node":{"type":"View"}},
              {"op":"createNode","id":"source","node":{"type":"View"}},
              {"op":"createNode","id":"destination","node":{"type":"View"}},
              {"op":"createNode","id":"popup","node":{"type":"TextInput","key":"popup"}},
              {"op":"insertChild","parentId":"root","childId":"source","index":0},
              {"op":"insertChild","parentId":"root","childId":"destination","index":1},
              {"op":"insertChild","parentId":"source","childId":"popup","index":0}
            ]
        """.trimIndent()))
        val result = document.apply(batch(2, """
            [{"op":"reparentChild","parentId":"destination","childId":"popup","index":0}]
        """.trimIndent()))
        assertEquals("destination", document.parentId("popup"))
        assertEquals(listOf("destination", "source"), result.affectedNodeIds)
        assertEquals(true, result.requiresFullRender)
        assertEquals("popup", document.node("destination")?.getJSONArray("children")?.getJSONObject(0)?.getString("id"))
    }

    @Test
    fun replacesKeyedListChildrenAtomically() {
        val document = CraftNativeMutationDocument()
        document.apply(batch(1, """
            [
              {"op":"createNode","id":"root","root":true,"node":{"type":"View"}},
              {"op":"createNode","id":"list","node":{"type":"FlatList"}},
              {"op":"createNode","id":"first","node":{"type":"Text","key":"first","children":["First"]}},
              {"op":"createNode","id":"second","node":{"type":"Text","key":"second","children":["Second"]}},
              {"op":"createNode","id":"third","node":{"type":"Text","key":"third","children":["Third"]}},
              {"op":"insertChild","parentId":"root","childId":"list","index":0},
              {"op":"replaceChildren","parentId":"list","children":["first","second","third"]}
            ]
        """.trimIndent()))

        val result = document.apply(batch(2, """
            [{"op":"replaceChildren","parentId":"list","children":["third","first"]}]
        """.trimIndent()))
        assertEquals(listOf("list"), result.affectedNodeIds)
        assertEquals(false, result.requiresFullRender)
        val rows = document.node("list")?.getJSONArray("children")
        assertEquals(listOf("third", "first"), (0 until rows!!.length()).map { rows.getJSONObject(it).getString("id") })
        assertNull(document.node("second"))

        val failure = failure(document, batch(3, """
            [{"op":"replaceChildren","parentId":"list","children":["first","first"]}]
        """.trimIndent()))
        assertEquals("DUPLICATE_CHILD", failure.code)
        assertEquals(2, document.revision)
        assertEquals("list", document.parentId("third"))
    }

    @Test
    fun reparentingRetainsThePopupSubtreeAndAuthoredKeys() {
        val document = CraftNativeMutationDocument()
        document.replace(JSONObject("""
            {"id":"root","type":"View","children":[
              {"id":"source","type":"ScrollView","children":[
                {"id":"popup","type":"View","key":"popup-key","children":[
                  {"id":"field","type":"TextInput","key":"field-key","props":{"value":"draft"}}
                ]}
              ]},
              {"id":"destination","type":"Modal","children":[]}
            ]}
        """.trimIndent()))

        val result = document.apply(batch(1, """
            [{"op":"reparentChild","parentId":"destination","childId":"popup","index":0}]
        """.trimIndent(), base = 0))

        assertEquals(true, result.requiresFullRender)
        val popup = document.node("destination")?.getJSONArray("children")?.getJSONObject(0)
        assertEquals("popup-key", popup?.getString("key"))
        val field = popup?.getJSONArray("children")?.getJSONObject(0)
        assertEquals("field", field?.getString("id"))
        assertEquals("field-key", field?.getString("key"))
        assertEquals("draft", field?.getJSONObject("props")?.getString("value"))
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

    @Test
    fun keepsMapOverlayParentsAddressableForTargetedUpdates() {
        val document = CraftNativeMutationDocument()
        document.apply(batch(1, """
            [
              {"op":"createNode","id":"root","root":true,"node":{"type":"View"}},
              {"op":"createNode","id":"map","node":{"type":"Map"}},
              {"op":"createNode","id":"route","node":{"type":"MapPolyline","props":{"geometry":[47,11,47.1,11.2]}}},
              {"op":"insertChild","parentId":"root","childId":"map","index":0},
              {"op":"insertChild","parentId":"map","childId":"route","index":0}
            ]
        """.trimIndent()))
        assertEquals("map", document.parentId("route"))
        assertEquals("Map", document.node("map")?.getString("type"))

        val update = document.apply(batch(2, """
            [{"op":"updateNode","id":"route","patch":{"props":{"geometry":[47,11,47.2,11.4]}}}]
        """.trimIndent()))
        assertEquals(listOf("route"), update.updatedNodeIds)
        assertEquals(listOf("route"), update.affectedNodeIds)
        assertEquals(false, update.requiresFullRender)
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
