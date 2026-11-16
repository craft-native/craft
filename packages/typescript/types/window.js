// `craft-native/window` is the declarations in `craft.d.ts`: a native host
// injects `window.craft` itself, so there is nothing to load. This empty module
// lets `import 'craft-native/window'` resolve at runtime as well as in types.
export {}
