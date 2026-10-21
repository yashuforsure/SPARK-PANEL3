#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

#define BRIDGE_PORT 8088
#define HEAD_CAPSULE_RADIUS_BASE 0.15f
#define OFF_GET_HEAD_TF          0x376c660   // Get_Head_TF in UnityFramework
#define OFF_CAPSULE_RADIUS       0x64        // CapsuleCollider::set_radius
#define UF_IMAGE_NAME            "UnityFramework"

static float s_current_scale = 1.0f;
static float s_current_radius = HEAD_CAPSULE_RADIUS_BASE;
static int s_aimbot_enabled = 0;

static intptr_t get_unity_slide() {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, UF_IMAGE_NAME)) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static BOOL patch_memory_float(uintptr_t address, float value) {
    vm_address_t pageBase = (vm_address_t)(address & ~(PAGE_SIZE - 1));
    vm_size_t pageLen = PAGE_SIZE;
    kern_return_t kr = vm_protect(mach_task_self(), pageBase, pageLen, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return NO;
    *(float *)address = value;
    vm_protect(mach_task_self(), pageBase, pageLen, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return YES;
}

static void apply_in_memory_hitbox(float scale, float radius) {
    s_current_scale = scale;
    s_current_radius = radius;
    intptr_t slide = get_unity_slide();
    if (slide != 0) {
        uintptr_t headTFAddr = (uintptr_t)(slide + OFF_GET_HEAD_TF);
        uintptr_t radiusPatchAddr = headTFAddr + 0x1C + OFF_CAPSULE_RADIUS;
        patch_memory_float(radiusPatchAddr, radius);
        NSLog(@"[SPARK-BRIDGE] Patched in-memory head radius to %.4f (scale %.2fx)", radius, scale);
    } else {
        NSLog(@"[SPARK-BRIDGE] UnityFramework slide not found yet. Staged scale=%.2fx", scale);
    }
}

static void handle_client(int client_fd) {
    char buffer[2048] = {0};
    ssize_t bytes_read = read(client_fd, buffer, sizeof(buffer) - 1);
    if (bytes_read <= 0) {
        close(client_fd);
        return;
    }

    NSString *reqStr = [[NSString alloc] initWithBytes:buffer length:bytes_read encoding:NSUTF8StringEncoding];
    if (!reqStr) reqStr = @"";

    NSString *responseJson = @"{\"status\":\"unknown\"}";
    
    if ([reqStr containsString:@"GET /status"]) {
        responseJson = [NSString stringWithFormat:@"{\"status\":\"ok\",\"game\":\"Free Fire\",\"pid\":%d,\"hitbox\":%.2f,\"aimbot\":%d}",
                        getpid(), s_current_scale, s_aimbot_enabled];
    } else if ([reqStr containsString:@"GET /patch"]) {
        float scale = 1.0f;
        float radius = HEAD_CAPSULE_RADIUS_BASE;

        NSRange scaleRange = [reqStr rangeOfString:@"scale="];
        if (scaleRange.location != NSNotFound) {
            NSString *sub = [reqStr substringFromIndex:scaleRange.location + 6];
            NSScanner *scanner = [NSScanner scannerWithString:sub];
            [scanner scanFloat:&scale];
        }

        NSRange radiusRange = [reqStr rangeOfString:@"radius="];
        if (radiusRange.location != NSNotFound) {
            NSString *sub = [reqStr substringFromIndex:radiusRange.location + 7];
            NSScanner *scanner = [NSScanner scannerWithString:sub];
            [scanner scanFloat:&radius];
        } else {
            radius = HEAD_CAPSULE_RADIUS_BASE * scale;
        }

        apply_in_memory_hitbox(scale, radius);

        responseJson = [NSString stringWithFormat:@"{\"status\":\"ok\",\"applied\":true,\"scale\":%.2f,\"radius\":%.4f}",
                        scale, radius];
    }

    NSString *httpResponse = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: application/json\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n\r\n%@",
        (unsigned long)[responseJson lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        responseJson];

    const char *respBytes = [httpResponse UTF8String];
    write(client_fd, respBytes, strlen(respBytes));
    close(client_fd);
}

static void *bridge_server_thread(void *arg) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        NSLog(@"[SPARK-BRIDGE] socket() error");
        return NULL;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    address.sin_port = htons(BRIDGE_PORT);

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        NSLog(@"[SPARK-BRIDGE] bind() error on port %d", BRIDGE_PORT);
        close(server_fd);
        return NULL;
    }

    if (listen(server_fd, 8) < 0) {
        NSLog(@"[SPARK-BRIDGE] listen() error");
        close(server_fd);
        return NULL;
    }

    NSLog(@"[SPARK-BRIDGE] Server running on 127.0.0.1:%d", BRIDGE_PORT);

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t addrlen = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &addrlen);
        if (client_fd >= 0) {
            handle_client(client_fd);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void init_spark_bridge() {
    NSLog(@"[SPARK-BRIDGE] Initializing Localhost Bridge for Free Fire...");
    pthread_t thread;
    pthread_create(&thread, NULL, bridge_server_thread, NULL);
    pthread_detach(thread);
}
