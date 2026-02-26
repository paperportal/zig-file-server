//! Public WebDAV module entrypoint.

/// WebDAV server service implementation used by the app.
pub const WebDavService = @import("webdav/service.zig").WebDavService;
