#!/usr/bin/env tarantool

local ffi = require('ffi')
local bit = require('bit')

ffi.cdef([[
struct ifaddrs {
    struct ifaddrs  *ifa_next;    /* Next item in list */
    char            *ifa_name;    /* Name of interface */
    unsigned int     ifa_flags;   /* Flags from SIOCGIFFLAGS */
    struct sockaddr *ifa_addr;    /* Address of interface */
    struct sockaddr *ifa_netmask; /* Netmask of interface */
    union {
        struct sockaddr *ifu_broadaddr;  /* Broadcast address of interface */
        struct sockaddr *ifu_dstaddr;    /* Point-to-point destination address */
    } ifa_ifu;
    void            *ifa_data;    /* Address-specific data */
};

struct in_addr {
    uint32_t s_addr;
};

enum {
    IFF_UP          = 0x1,  /* interface is up              */
    IFF_BROADCAST   = 0x2,  /* broadcast address valid      */
    IFF_POINTOPOINT = 0x10  /* interface is has p-p link    */
};

enum {
    AF_INET         = 2     /* Internet IP Protocol         */
};

const char *strerror(int errno);
int getifaddrs(struct ifaddrs **ifap);
void freeifaddrs(struct ifaddrs *ifa);
const char *inet_ntop(int af, const void *src,
                      char *dst, socklen_t size);
]])

if ffi.os == "Linux" then
    ffi.cdef([[
        struct sockaddr {
            uint16_t         sa_family;   /* address family, AF_xxx   */
            char             sa_data[14]; /* 14 bytes of protocol address */
        };

        /* Structure describing an Internet (IP) socket address. */
        struct sockaddr_in {
            uint16_t         sin_family; /* Address family       */
            uint16_t         sin_port;   /* Port number          */
            struct in_addr   sin_addr;   /* Internet address     */
        };
    ]])
elseif ffi.os == "OSX" then
    ffi.cdef([[
        struct sockaddr {
            uint8_t          sa_len;
            uint8_t          sa_family;   /* address family, AF_xxx   */
            char             sa_data[14]; /* 14 bytes of protocol address */
        };

        /* Structure describing an Internet (IP) socket address. */
        struct sockaddr_in {
            uint8_t          sin_len;
            uint8_t          sin_family; /* Address family       */
            uint16_t         sin_port;   /* Port number          */
            struct in_addr   sin_addr;   /* Internet address     */
        };
    ]])
end

--- List active AF_INET interfaces.
-- Compose a table of the following structure:
-- {
--     [1] = {
--         name = ifa_name,
--         inet4 = "0.0.0.0",
--         bcast = "0.0.0.0", -- if broadcast flag is set
--     },
-- }
local function getifaddrs()
    local ifaddrs_root = ffi.new("struct ifaddrs *[1]")
    local res = ffi.C.getifaddrs(ifaddrs_root)
    if res ~= 0 then
        local errno = ffi.errno()
        local strerr = ffi.C.strerror(errno)
        error(ffi.string(strerr))
    end

    local ret = {}
    local buf = ffi.new("char[32]")
    local iap = ifaddrs_root[0]
    while iap ~= nil do
        if bit.band(iap.ifa_flags, ffi.C.IFF_UP) ~= 0 then
            local ifa = {}
            ifa.name = ffi.string(iap.ifa_name)

            if iap.ifa_addr ~= nil and iap.ifa_addr.sa_family == ffi.C.AF_INET then
                local sa = ffi.cast("struct sockaddr_in *", iap.ifa_addr)
                ffi.C.inet_ntop(sa.sin_family, sa.sin_addr, buf, ffi.sizeof(buf))
                ifa.inet4 = ffi.string(buf)

                if bit.band(iap.ifa_flags, ffi.C.IFF_BROADCAST) ~= 0 then
                    local sa = ffi.cast("struct sockaddr_in *", iap.ifa_ifu.ifu_broadaddr)
                    ffi.C.inet_ntop(sa.sin_family, sa.sin_addr, buf, ffi.sizeof(buf))
                    ifa.bcast = ffi.string(buf)
                end

                table.insert(ret, ifa)
            end
        end
        iap = iap.ifa_next
    end

    ffi.C.freeifaddrs(ifaddrs_root[0])
    return ret
end

return {
    getifaddrs = getifaddrs,
}
