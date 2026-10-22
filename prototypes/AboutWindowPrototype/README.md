# About Window Prototype

A standalone AppKit prototype for the Movie Folder Posters About window. It uses the
app icon as the primary product mark and places TMDb attribution in a compact,
secondary footer.

Build the app bundle from this directory:

```sh
bash run.sh
```

The script compiles `main.swift` with the system Swift compiler and creates
`build/AboutWindowPrototype-Review.app`. Open that app bundle in Finder to launch
the prototype. It does not modify or build the product app. Assets are local copies of
the app icon and official TMDb logo used by the current R100-09 implementation.
