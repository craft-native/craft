# @craft-native/ts-maps

Craft SDK bindings for the [ts-maps](https://github.com/stacksjs/ts-maps) interactive map runtime.

This package is the TypeScript side of `MapProvider.ts_maps` in Craft's Zig core.
Its `MapView` owns a DOM container and renders ts-maps inside a browser or
WebView, with zero API keys. It is not the STX native `Map` component.

For a fully native STX screen, use `Map`, `MapMarker`, and `MapPolyline`.
Craft renders them with MapKit on iOS and the configured native Android map
provider. Android's `mapProvider: 'maplibre'` selects a key-free native GL view;
it does not mount this package's DOM adapter.

## Install

```bash
bun add @craft-native/ts-maps
```

`ts-maps` comes with it as a dependency, so there is nothing else to install. A
project that type-checks dependencies (`skipLibCheck: false`) will see three
errors inside `ts-maps`'s own declarations (`ProjectionLike` and a generator in
`PMTiles.d.ts`). They come from that package, not from this adapter, and
`skipLibCheck: true` hides them.

## Quick start

```ts
import { createMapView, defaultMapConfiguration, tsMapsProvider } from '@craft-native/ts-maps'

const view = createMapView({
  configuration: { ...defaultMapConfiguration, provider: tsMapsProvider },
  initialCamera: {
    center: { latitude: 37.7749, longitude: -122.4194 },
    zoom: 12,
    pitch: 0,
    heading: 0,
  },
  markers: [
    {
      id: 1,
      coordinate: { latitude: 37.7749, longitude: -122.4194 },
      title: 'San Francisco',
      subtitle: null,
      color: 'red',
      is_draggable: false,
      is_selected: false,
      custom_icon: null,
      anchor_x: 0.5,
      anchor_y: 1,
    },
  ],
  onTap: (coord) => console.log('tapped', coord),
  onMarkerTap: (id, coord) => console.log('marker', id, coord),
})

document.body.appendChild(view.container)
```

## API overview

| Export | What it is |
| --- | --- |
| `createMapView(props)` | Factory returning a `MapViewInstance` with `id`, `container`, `map`, and imperative methods (`setCamera`, `addMarker`, `fitToMarkers`, …). |
| `MapViewProps` / `MapViewInstance` | Types for the component. |
| `Coordinate`, `MapRegion`, `MapCamera`, `MapMarker`, … | TypeScript mirrors of the structs in `packages/zig/src/maps.zig`. Field names match exactly so JSON round-trips are free. |
| `craftCoordToLatLng`, `latLngToCraftCoord`, `craftRegionToBounds`, `craftCameraToOptions`, `craftMarkerToMarker`, … | Pure adapter functions between Craft and ts-maps types. |
| `tsMapsProvider` | Constant `'ts_maps'` that matches the Zig enum tag. |
| Everything from `ts-maps` | `TsMap`, `LatLng`, `Marker`, `Polyline`, `marker()`, `tileLayer()`, etc. are re-exported so you only need one import. |

## Bridge protocol

When running inside a Craft WebView, `createMapView` registers itself with `getBridge()` and listens for the methods declared in `./bridge-protocol`:

- `setCamera`, `setRegion`, `addMarker`, `removeMarker`, `addPolyline`, `addPolygon`, `addCircle`, `fitToMarkers`, `selectMarker`, `deselectAll`, `setConfiguration`.

It emits these events back:

- `map:tap`, `map:markerTap`, `map:regionChanged`, `map:cameraChanged`.

If no bridge is available (browser-only, tests, etc.) the component silently falls back to local-only behavior — event callbacks passed via props still fire.

## Development

```bash
bun run typecheck
bun test
bunx --bun pickier .
```
