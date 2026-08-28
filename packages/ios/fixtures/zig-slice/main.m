// Entry point for the Phase 1 vertical-slice fixture.
//
// `_main` lives here rather than in the Zig static library on purpose: a
// static archive only contributes the objects the linker is asked for, and a
// `main` buried in one is exactly the symbol a linker will not go looking for.
// Three lines of Objective-C is a smaller price than `-force_load`.
extern int craft_ios_init(void);
extern void craft_ios_set_html(const char *html, unsigned long len);
extern int craft_ios_main(int argc, char **argv);

extern const char craft_slice_page[];
extern const unsigned long craft_slice_page_len;

int main(int argc, char **argv) {
    craft_ios_init();
    craft_ios_set_html(craft_slice_page, craft_slice_page_len);
    return craft_ios_main(argc, argv);
}
