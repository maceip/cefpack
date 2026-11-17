# The C ABI: what the consumer links against

The engine that this repository builds is a shared library.  A consumer — the
Rust crate that binds it — links against that library, and the linker resolves
every symbol that the consumer **references**.  A symbol that the consumer
does not reference does not have to exist; a symbol that it does reference and
that the engine does not export stops the link:

```text
undefined reference to `cef_browser_host_create_browser'
```

This document is the contract between the two, and it is **measured**, not
assumed:

* the *required* symbols were read out of the objects of the consumer, for
  `aarch64-linux-android`, with the symbols that the linker has to resolve —
  190 of them;
* the *declared* symbols were read out of the headers of the pinned checkout
  of CEF (`6028375a4532fb89d23b58635f5c0d3a82c93959`), which is what the
  engine exports.

The audit is a command of the service, and it runs against any checkout:

```bash
cefpack abi <checkout of CEF>
```

## The three tiers of the headers

CEF declares its C functions in three places, and the difference matters for a
build for Android:

| tier | the headers | what it is | declared | needed |
|---|---|---|---|---|
| base | `include/` | the version and the hash of the API | 10 | 2 |
| published | `include/capi/` | the C API that the engine promises | 111 | 110 |
| views | `include/capi/views/` | the C API of the framework of the views | 17 | 17 |
| internal | `include/internal/` | the helpers of the strings, the times and the lists | 78 | 61 |

**Every symbol the consumer needs is declared by the engine.**  There is
nothing missing, and the shim has 190 functions to implement.

The tier of the **views** is the one that cannot be built for Android: the
framework of the views is the user interface of the desktop browser, and
Chromium builds it for the desktop platforms only.  The seventeen symbols of
that tier are the ones that the shim **stubs**:

```
cef_browser_view_create            cef_display_get_alls
cef_browser_view_get_for_browser   cef_display_get_count
cef_display_convert_screen_point_from_pixels   cef_display_get_matching_bounds
cef_display_convert_screen_point_to_pixels     cef_display_get_nearest_point
cef_display_convert_screen_rect_from_pixels    cef_display_get_primary
cef_display_convert_screen_rect_to_pixels      cef_label_button_create
cef_menu_button_create             cef_panel_create
cef_scroll_view_create             cef_textfield_create
cef_window_create_top_level
```

They return an empty result — a null handle, a false flag — and the consumer
never reaches them, because the consumer builds no window and no view: the
browser is rendered **off screen**.

## The objects of the C API are C++ objects with a vtable

This is the fact that decides the size of the C++ side.  A type of the C API
is not an opaque pointer: it is a struct with a size, a pointer to the object,
and a **table of function pointers**:

```c
typedef struct _cef_browser_t {
  int size;
  void* self;
  int (CEF_CALLBACK *is_valid)(struct _cef_browser_t* self);
  ...
```

The pinned API declares **144** such structs, with **1 268** callbacks
between them — that is what a complete implementation of the C API of CEF
would be.

The consumer uses a small part of it.  It installs seven handlers, and this
is the whole of the C++ that has to be written for it:

| the type of the C API | the callbacks of its vtable | what it does in Trap |
|---|---|---|
| `cef_client_t` | 19 | the client that the application passes to the engine |
| `cef_app_t` | 5 | the application of the engine: the command line, the work of the main loop |
| `cef_life_span_handler_t` | 6 | the creation and the shutdown of the browser |
| `cef_render_handler_t` | 17 | **the paint: the capture of the frame** |
| `cef_load_handler_t` | 4 | the navigation |
| `cef_request_handler_t` | 11 | the policy of the addresses |
| `cef_resource_request_handler_t` | 8 | the subresources |
| `cef_render_process_handler_t` | 9 | the DOM, in the renderer |

Seventy-nine callbacks in all.  The shim fills the vtables of those seven
handlers, and the vtables of the objects it hands back — the browser, the
browser host, the frame — are its own.

## The structs

The structures of the C API are the vtables above.  The rest of the types are
the flags, and every flag of the C API is an `int`:

```c
typedef int cef_event_flags_t;
typedef int cef_urlrequest_flags_t;
typedef int cef_context_menu_type_flags_t;
```

and the opaque handles are pointers to structs that the consumer never
dereferences:

```c
typedef struct _cef_browser_t* cef_browser_t;
```

The only structure with a layout of its own is the state of a touch handle,
and the engine checks its size at run time, so the shim must lay it out
exactly:

```c
struct _cef_touch_handle_state_t {
  size_t size;
  int touch_handle_id;
  cef_touch_handle_state_flags_t flags;
  int enabled;
  cef_horizontal_alignment_t orientation;
  int mirror_vertical;
  int mirror_horizontal;
  cef_point_t origin;
  float alpha;
};
```

## The list of the prototypes

The prototypes below are the ones of the headers of the pinned checkout, and
they are the contract that the shim implements.  The command `cefpack abi`
prints them again from any checkout, so the two cannot drift apart without a
diff that says so.


--- base (2 symbols) ---
const char* cef_api_hash(int version, int entry);
int cef_api_version(void);

--- published (110 symbols) ---
int cef_execute_process(const cef_main_args_t* args, cef_app_t* application, void* windows_sandbox_info);
int cef_initialize(const cef_main_args_t* args, const struct _cef_settings_t* settings, cef_app_t* application, void* windows_sandbox_info);
int cef_get_exit_code(void);
void cef_shutdown(void);
void cef_do_message_loop_work(void);
void cef_run_message_loop(void);
void cef_quit_message_loop(void);
void cef_set_nestable_tasks_allowed(int allowed);
int cef_browser_host_create_browser(const cef_window_info_t* windowInfo, struct _cef_client_t* client, const cef_string_t* url, const struct _cef_browser_settings_t* settings, struct _cef_dictionary_value_t* extra_info, struct _cef_request_context_t* request_context);
cef_browser_t* cef_browser_host_create_browser_sync(const cef_window_info_t* windowInfo, struct _cef_client_t* client, const cef_string_t* url, const struct _cef_browser_settings_t* settings, struct _cef_dictionary_value_t* extra_info, struct _cef_request_context_t* request_context);
cef_browser_t* cef_browser_host_get_browser_by_identifier(int browser_id);
cef_command_line_t* cef_command_line_create(void);
cef_command_line_t* cef_command_line_get_global(void);
cef_component_updater_t* cef_component_updater_get(void);
cef_cookie_manager_t* cef_cookie_manager_get_global_manager(struct _cef_completion_callback_t* callback);
int cef_crash_reporting_enabled(void);
void cef_set_crash_key_value(const cef_string_t* key, const cef_string_t* value);
cef_drag_data_t* cef_drag_data_create(void);
int cef_create_directory(const cef_string_t* full_path);
int cef_get_temp_directory(cef_string_t* temp_dir);
int cef_create_new_temp_directory(const cef_string_t* prefix, cef_string_t* new_temp_path);
int cef_create_temp_directory_in_directory(const cef_string_t* base_dir, const cef_string_t* prefix, cef_string_t* new_dir);
int cef_directory_exists(const cef_string_t* path);
int cef_delete_file(const cef_string_t* path, int recursive);
int cef_zip_directory(const cef_string_t* src_dir, const cef_string_t* dest_file, int include_hidden_files);
void cef_load_crlsets_file(const cef_string_t* path);
int cef_is_rtl(void);
cef_image_t* cef_image_create(void);
cef_media_router_t* cef_media_router_get_global(struct _cef_completion_callback_t* callback);
cef_menu_model_t* cef_menu_model_create(struct _cef_menu_model_delegate_t* delegate);
int cef_add_cross_origin_whitelist_entry(const cef_string_t* source_origin, const cef_string_t* target_protocol, const cef_string_t* target_domain, int allow_target_subdomains);
int cef_remove_cross_origin_whitelist_entry(const cef_string_t* source_origin, const cef_string_t* target_protocol, const cef_string_t* target_domain, int allow_target_subdomains);
int cef_clear_cross_origin_whitelist(void);
int cef_resolve_url(const cef_string_t* base_url, const cef_string_t* relative_url, cef_string_t* resolved_url);
int cef_parse_url(const cef_string_t* url, struct _cef_urlparts_t* parts);
int cef_create_url(const struct _cef_urlparts_t* parts, cef_string_t* url);
cef_string_userfree_t cef_format_url_for_security_display(const cef_string_t* origin_url);
cef_string_userfree_t cef_get_mime_type(const cef_string_t* extension);
void cef_get_extensions_for_mime_type(const cef_string_t* mime_type, cef_string_list_t extensions);
cef_string_userfree_t cef_base64_encode(const void* data, size_t data_size);
struct _cef_binary_value_t* cef_base64_decode(const cef_string_t* data);
cef_string_userfree_t cef_uriencode(const cef_string_t* text, int use_plus);
cef_string_userfree_t cef_uridecode(const cef_string_t* text, int convert_to_utf8, cef_uri_unescape_rule_t unescape_rule);
struct _cef_value_t* cef_parse_json(const cef_string_t* json_string, cef_json_parser_options_t options);
struct _cef_value_t* cef_parse_json_buffer(const void* json, size_t json_size, cef_json_parser_options_t options);
struct _cef_value_t* cef_parse_jsonand_return_error(const cef_string_t* json_string, cef_json_parser_options_t options, cef_string_t* error_msg_out);
cef_string_userfree_t cef_write_json(struct _cef_value_t* node, cef_json_writer_options_t options);
int cef_get_path(cef_path_key_t key, cef_string_t* path);
void cef_preference_manager_get_chrome_variations_as_switches(cef_string_list_t switches);
void cef_preference_manager_get_chrome_variations_as_strings(cef_string_list_t strings);
cef_preference_manager_t* cef_preference_manager_get_global(void);
cef_print_settings_t* cef_print_settings_create(void);
cef_process_message_t* cef_process_message_create(const cef_string_t* name);
int cef_launch_process(struct _cef_command_line_t* command_line);
cef_request_t* cef_request_create(void);
cef_post_data_t* cef_post_data_create(void);
cef_post_data_element_t* cef_post_data_element_create(void);
cef_request_context_t* cef_request_context_get_global_context(void);
cef_request_context_t* cef_request_context_create_context(const struct _cef_request_context_settings_t* settings, struct _cef_request_context_handler_t* handler);
cef_request_context_t* cef_request_context_cef_create_context_shared(cef_request_context_t* other, struct _cef_request_context_handler_t* handler);
cef_resource_bundle_t* cef_resource_bundle_get_global(void);
cef_response_t* cef_response_create(void);
int cef_register_scheme_handler_factory(const cef_string_t* scheme_name, const cef_string_t* domain_name, cef_scheme_handler_factory_t* factory);
int cef_clear_scheme_handler_factories(void);
void cef_server_create(const cef_string_t* address, uint16_t port, int backlog, struct _cef_server_handler_t* handler);
cef_shared_process_message_builder_t* cef_shared_process_message_builder_create(const cef_string_t* name, size_t byte_size);
int cef_is_cert_status_error(cef_cert_status_t status);
cef_stream_reader_t* cef_stream_reader_create_for_file(const cef_string_t* fileName);
cef_stream_reader_t* cef_stream_reader_create_for_data(void* data, size_t size);
cef_stream_reader_t* cef_stream_reader_create_for_handler(cef_read_handler_t* handler);
cef_stream_writer_t* cef_stream_writer_create_for_file(const cef_string_t* fileName);
cef_stream_writer_t* cef_stream_writer_create_for_handler(cef_write_handler_t* handler);
cef_task_runner_t* cef_task_runner_get_for_current_thread(void);
cef_task_runner_t* cef_task_runner_get_for_thread(cef_thread_id_t threadId);
int cef_currently_on(cef_thread_id_t threadId);
int cef_post_task(cef_thread_id_t threadId, cef_task_t* task);
int cef_post_delayed_task(cef_thread_id_t threadId, cef_task_t* task, int64_t delay_ms);
cef_task_manager_t* cef_task_manager_get(void);
cef_thread_t* cef_thread_create(const cef_string_t* display_name, cef_thread_priority_t priority, cef_message_loop_type_t message_loop_type, int stoppable, cef_com_init_mode_t com_init_mode);
int cef_begin_tracing(const cef_string_t* categories, struct _cef_completion_callback_t* callback);
int cef_end_tracing(const cef_string_t* tracing_file, cef_end_tracing_callback_t* callback);
int64_t cef_now_from_system_trace_time(void);
cef_urlrequest_t* cef_urlrequest_create(struct _cef_request_t* request, struct _cef_urlrequest_client_t* client, struct _cef_request_context_t* request_context);
cef_v8_context_t* cef_v8_context_get_current_context(void);
cef_v8_context_t* cef_v8_context_get_entered_context(void);
int cef_v8_context_in_context(void);
cef_v8_backing_store_t* cef_v8_backing_store_create(size_t byte_length);
cef_v8_value_t* cef_v8_value_create_undefined(void);
cef_v8_value_t* cef_v8_value_create_null(void);
cef_v8_value_t* cef_v8_value_create_bool(int value);
cef_v8_value_t* cef_v8_value_create_int(int32_t value);
cef_v8_value_t* cef_v8_value_create_uint(uint32_t value);
cef_v8_value_t* cef_v8_value_create_double(double value);
cef_v8_value_t* cef_v8_value_create_date(cef_basetime_t date);
cef_v8_value_t* cef_v8_value_create_string(const cef_string_t* value);
cef_v8_value_t* cef_v8_value_create_object(cef_v8_accessor_t* accessor, cef_v8_interceptor_t* interceptor);
cef_v8_value_t* cef_v8_value_create_array(int length);
cef_v8_value_t* cef_v8_value_create_array_buffer(void* buffer, size_t length, cef_v8_array_buffer_release_callback_t* release_callback);
cef_v8_value_t* cef_v8_value_create_array_buffer_with_copy(void* buffer, size_t length);
cef_v8_value_t* cef_v8_value_create_array_buffer_from_backing_store(cef_v8_backing_store_t* backing_store);
cef_v8_value_t* cef_v8_value_create_function(const cef_string_t* name, cef_v8_handler_t* handler);
cef_v8_value_t* cef_v8_value_create_promise(void);
cef_v8_stack_trace_t* cef_v8_stack_trace_get_current(int frame_limit);
cef_value_t* cef_value_create(void);
cef_binary_value_t* cef_binary_value_create(const void* data, size_t data_size);
cef_dictionary_value_t* cef_dictionary_value_create(void);
cef_list_value_t* cef_list_value_create(void);
cef_waitable_event_t* cef_waitable_event_create(int automatic_reset, int initially_signaled);
cef_xml_reader_t* cef_xml_reader_create(struct _cef_stream_reader_t* stream, cef_xml_encoding_type_t encodingType, const cef_string_t* URI);
cef_zip_reader_t* cef_zip_reader_create(struct _cef_stream_reader_t* stream);

--- views (17 symbols) ---
cef_browser_view_t* cef_browser_view_create(struct _cef_client_t* client, const cef_string_t* url, const struct _cef_browser_settings_t* settings, struct _cef_dictionary_value_t* extra_info, struct _cef_request_context_t* request_context, struct _cef_browser_view_delegate_t* delegate);
cef_browser_view_t* cef_browser_view_get_for_browser(struct _cef_browser_t* browser);
cef_display_t* cef_display_get_primary(void);
cef_display_t* cef_display_get_nearest_point(const cef_point_t* point, int input_pixel_coords);
cef_display_t* cef_display_get_matching_bounds(const cef_rect_t* bounds, int input_pixel_coords);
size_t cef_display_get_count(void);
void cef_display_get_alls(size_t* displaysCount, cef_display_t** displays);
cef_point_t cef_display_convert_screen_point_to_pixels(const cef_point_t* point);
cef_point_t cef_display_convert_screen_point_from_pixels(const cef_point_t* point);
cef_rect_t cef_display_convert_screen_rect_to_pixels(const cef_rect_t* rect);
cef_rect_t cef_display_convert_screen_rect_from_pixels(const cef_rect_t* rect);
cef_label_button_t* cef_label_button_create(struct _cef_button_delegate_t* delegate, const cef_string_t* text);
cef_menu_button_t* cef_menu_button_create(struct _cef_menu_button_delegate_t* delegate, const cef_string_t* text);
cef_panel_t* cef_panel_create(struct _cef_panel_delegate_t* delegate);
cef_scroll_view_t* cef_scroll_view_create(struct _cef_view_delegate_t* delegate);
cef_textfield_t* cef_textfield_create(struct _cef_textfield_delegate_t* delegate);
cef_window_t* cef_window_create_top_level(struct _cef_window_delegate_t* delegate);

--- internal (61 symbols) ---
cef_string_list_t cef_string_list_alloc(void);
size_t cef_string_list_size(cef_string_list_t list);
int cef_string_list_value(cef_string_list_t list, size_t index, cef_string_t* value);
void cef_string_list_append(cef_string_list_t list, const cef_string_t* value);
void cef_string_list_clear(cef_string_list_t list);
void cef_string_list_free(cef_string_list_t list);
cef_string_list_t cef_string_list_copy(cef_string_list_t list);
cef_string_map_t cef_string_map_alloc(void);
size_t cef_string_map_size(cef_string_map_t map);
int cef_string_map_find(cef_string_map_t map, const cef_string_t* key, cef_string_t* value);
int cef_string_map_key(cef_string_map_t map, size_t index, cef_string_t* key);
int cef_string_map_value(cef_string_map_t map, size_t index, cef_string_t* value);
int cef_string_map_append(cef_string_map_t map, const cef_string_t* key, const cef_string_t* value);
void cef_string_map_clear(cef_string_map_t map);
void cef_string_map_free(cef_string_map_t map);
cef_string_multimap_t cef_string_multimap_alloc(void);
size_t cef_string_multimap_size(cef_string_multimap_t map);
size_t cef_string_multimap_find_count(cef_string_multimap_t map, const cef_string_t* key);
int cef_string_multimap_enumerate(cef_string_multimap_t map, const cef_string_t* key, size_t value_index, cef_string_t* value);
int cef_string_multimap_key(cef_string_multimap_t map, size_t index, cef_string_t* key);
int cef_string_multimap_value(cef_string_multimap_t map, size_t index, cef_string_t* value);
int cef_string_multimap_append(cef_string_multimap_t map, const cef_string_t* key, const cef_string_t* value);
void cef_string_multimap_clear(cef_string_multimap_t map);
void cef_string_multimap_free(cef_string_multimap_t map);
int cef_string_wide_set(const wchar_t* src, size_t src_len, cef_string_wide_t* output, int copy);
int cef_string_utf8_set(const char* src, size_t src_len, cef_string_utf8_t* output, int copy);
int cef_string_utf16_set(const char16_t* src, size_t src_len, cef_string_utf16_t* output, int copy);
void cef_string_wide_clear(cef_string_wide_t* str);
void cef_string_utf8_clear(cef_string_utf8_t* str);
void cef_string_utf16_clear(cef_string_utf16_t* str);
int cef_string_wide_cmp(const cef_string_wide_t* str1, const cef_string_wide_t* str2);
int cef_string_utf8_cmp(const cef_string_utf8_t* str1, const cef_string_utf8_t* str2);
int cef_string_utf16_cmp(const cef_string_utf16_t* str1, const cef_string_utf16_t* str2);
int cef_string_wide_to_utf8(const wchar_t* src, size_t src_len, cef_string_utf8_t* output);
int cef_string_utf8_to_wide(const char* src, size_t src_len, cef_string_wide_t* output);
int cef_string_wide_to_utf16(const wchar_t* src, size_t src_len, cef_string_utf16_t* output);
int cef_string_utf16_to_wide(const char16_t* src, size_t src_len, cef_string_wide_t* output);
int cef_string_utf8_to_utf16(const char* src, size_t src_len, cef_string_utf16_t* output);
int cef_string_utf16_to_utf8(const char16_t* src, size_t src_len, cef_string_utf8_t* output);
int cef_string_ascii_to_wide(const char* src, size_t src_len, cef_string_wide_t* output);
int cef_string_ascii_to_utf16(const char* src, size_t src_len, cef_string_utf16_t* output);
cef_string_userfree_wide_t cef_string_userfree_wide_alloc(void);
cef_string_userfree_utf8_t cef_string_userfree_utf8_alloc(void);
cef_string_userfree_utf16_t cef_string_userfree_utf16_alloc(void);
void cef_string_userfree_wide_free(cef_string_userfree_wide_t str);
void cef_string_userfree_utf8_free(cef_string_userfree_utf8_t str);
void cef_string_userfree_utf16_free(cef_string_userfree_utf16_t str);
int cef_string_utf16_to_lower(const char16_t* src, size_t src_len, cef_string_utf16_t* output);
int cef_string_utf16_to_upper(const char16_t* src, size_t src_len, cef_string_utf16_t* output);
cef_platform_thread_id_t cef_get_current_platform_thread_id(void);
cef_platform_thread_handle_t cef_get_current_platform_thread_handle(void);
int cef_time_to_timet(const cef_time_t* cef_time, time_t* time);
int cef_time_from_timet(time_t time, cef_time_t* cef_time);
int cef_time_to_doublet(const cef_time_t* cef_time, double* time);
int cef_time_from_doublet(double time, cef_time_t* cef_time);
int cef_time_now(cef_time_t* cef_time);
cef_basetime_t cef_basetime_now(void);
int cef_time_delta(const cef_time_t* cef_time1, const cef_time_t* cef_time2, long long* delta);
int cef_time_to_basetime(const cef_time_t* from, cef_basetime_t* to);
int cef_time_from_basetime(const cef_basetime_t from, cef_time_t* to);
XDisplay* cef_get_xdisplay(void);
