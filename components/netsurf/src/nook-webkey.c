/*
 * nook-webkey.c - Lightweight Remote Phone Keyboard & Controller Web Daemon
 * Runs on port 8080 to allow instant smartphone typing and navigation on BNRV700
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ctype.h>

#define PORT 8080
#define FIFO_PATH "/tmp/netsurf_input.fifo"

static int fifo_write(const char *cmd) {
    int fd = open(FIFO_PATH, O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    int len = strlen(cmd);
    int written = write(fd, cmd, len);
    close(fd);
    return written;
}

static void url_decode(char *dst, const char *src, size_t max_len) {
    size_t d = 0;
    while (*src && d + 1 < max_len) {
        if (*src == '%' && isxdigit(src[1]) && isxdigit(src[2])) {
            char hex[3] = { src[1], src[2], '\0' };
            dst[d++] = (char)strtol(hex, NULL, 16);
            src += 3;
        } else if (*src == '+') {
            dst[d++] = ' ';
            src++;
        } else {
            dst[d++] = *src++;
        }
    }
    dst[d] = '\0';
}

static const char *HTML_PAGE =
"<!DOCTYPE html>\n"
"<html lang='en'>\n"
"<head>\n"
"<meta charset='UTF-8'>\n"
"<meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no'>\n"
"<title>NOOK Remote Keyboard</title>\n"
"<style>\n"
"  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }\n"
"  body { background: #121214; color: #f0f0f2; padding: 16px; max-width: 540px; margin: 0 auto; }\n"
"  header { text-align: center; margin-bottom: 20px; padding-bottom: 12px; border-bottom: 1px solid #282830; }\n"
"  h1 { font-size: 20px; font-weight: 700; color: #fff; }\n"
"  .status { font-size: 13px; color: #4ade80; margin-top: 4px; display: inline-flex; align-items: center; gap: 6px; }\n"
"  .dot { width: 8px; height: 8px; border-radius: 50%; background: #4ade80; display: inline-block; }\n"
"  .card { background: #1e1e24; border-radius: 12px; padding: 16px; margin-bottom: 16px; border: 1px solid #2e2e38; }\n"
"  .card-title { font-size: 14px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: #a0a0b0; margin-bottom: 12px; }\n"
"  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }\n"
"  .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; }\n"
"  button, .btn { background: #2a2a36; color: #fff; border: 1px solid #3c3c4c; border-radius: 8px; padding: 14px 10px; font-size: 15px; font-weight: 600; cursor: pointer; text-align: center; user-select: none; -webkit-tap-highlight-color: transparent; transition: background 0.1s; }\n"
"  button:active, .btn:active { background: #4a4a5c; transform: scale(0.98); }\n"
"  .btn-primary { background: #2563eb; border-color: #3b82f6; }\n"
"  .btn-primary:active { background: #1d4ed8; }\n"
"  .btn-green { background: #059669; border-color: #10b981; }\n"
"  .btn-green:active { background: #047857; }\n"
"  .btn-amber { background: #d97706; border-color: #f59e0b; }\n"
"  .btn-amber:active { background: #b45309; }\n"
"  input[type='text'], input[type='url'] { width: 100%; padding: 14px; border-radius: 8px; border: 1px solid #3c3c4c; background: #141418; color: #fff; font-size: 16px; margin-bottom: 10px; outline: none; }\n"
"  input[type='text']:focus, input[type='url']:focus { border-color: #3b82f6; ring: 2px solid #3b82f6; }\n"
"  .hint { font-size: 12px; color: #808090; margin-top: 6px; }\n"
"  #feedback { font-size: 12px; color: #a0a0b0; min-height: 18px; margin-top: 8px; text-align: center; }\n"
"</style>\n"
"</head>\n"
"<body>\n"
"<header>\n"
"  <h1>NOOK BNRV700 Remote</h1>\n"
"  <div class='status'><span class='dot'></span> Connected over Wi-Fi</div>\n"
"</header>\n"
"\n"
"<div class='card'>\n"
"  <div class='card-title'>Quick Navigation</div>\n"
"  <div class='grid-3'>\n"
"    <button class='btn-amber' onclick=\"sendCmd('focus_url')\">🔍 URL Bar</button>\n"
"    <button onclick=\"sendCmd('back')\">⬅️ Back</button>\n"
"    <button onclick=\"sendCmd('osk')\">⌨️ Toggle OSK</button>\n"
"  </div>\n"
"  <div class='grid' style='margin-top: 10px;'>\n"
"    <button onclick=\"sendCmd('pageup')\">⬆️ Page Up</button>\n"
"    <button onclick=\"sendCmd('pagedown')\">⬇️ Page Down</button>\n"
"  </div>\n"
"</div>\n"
"\n"
"<div class='card'>\n"
"  <div class='card-title'>Open URL or Search</div>\n"
"  <input type='text' id='urlInput' placeholder='Enter URL or search query...' autocomplete='off' autocorrect='off' autocapitalize='off'>\n"
"  <div class='grid'>\n"
"    <button class='btn-primary' onclick=\"sendUrl()\">🌐 Go to URL</button>\n"
"    <button class='btn-green' onclick=\"sendSearch()\">🔎 Search DuckDuckGo</button>\n"
"  </div>\n"
"  <div style='margin-top: 10px;'>\n"
"    <button style='width: 100%;' onclick=\"sendTextOnly()\">✍️ Type into Active Field</button>\n"
"  </div>\n"
"</div>\n"
"\n"
"<div class='card'>\n"
"  <div class='card-title'>Live Phone Keyboard</div>\n"
"  <input type='text' id='liveInput' placeholder='Tap here to type live from phone keyboard...' autocomplete='off' autocorrect='off' autocapitalize='off'>\n"
"  <div class='grid' style='margin-top: 8px;'>\n"
"    <button onclick=\"sendCmd('backspace')\">⌫ Backspace</button>\n"
"    <button class='btn-primary' onclick=\"sendCmd('enter')\">⏎ Enter / Go</button>\n"
"  </div>\n"
"  <div class='hint'>Each character typed above is sent immediately to your Nook screen.</div>\n"
"  <div id='feedback'></div>\n"
"</div>\n"
"\n"
"<script>\n"
"function notify(msg) {\n"
"  const el = document.getElementById('feedback');\n"
"  el.textContent = msg;\n"
"  setTimeout(() => { if (el.textContent === msg) el.textContent = ''; }, 2000);\n"
"}\n"
"\n"
"function sendCmd(cmd) {\n"
"  fetch('/cmd?k=' + encodeURIComponent(cmd))\n"
"    .then(r => notify('Command: ' + cmd))\n"
"    .catch(e => notify('Error: ' + e));\n"
"}\n"
"\n"
"function sendUrl() {\n"
"  let val = document.getElementById('urlInput').value.trim();\n"
"  if (!val) return;\n"
"  if (!val.startsWith('http://') && !val.startsWith('https://')) {\n"
"    val = 'https://' + val;\n"
"  }\n"
"  fetch('/url?u=' + encodeURIComponent(val))\n"
"    .then(r => {\n"
"      notify('Opening: ' + val);\n"
"      document.getElementById('urlInput').value = '';\n"
"    })\n"
"    .catch(e => notify('Error: ' + e));\n"
"}\n"
"\n"
"function sendSearch() {\n"
"  const val = document.getElementById('urlInput').value.trim();\n"
"  if (!val) return;\n"
"  const url = 'https://lite.duckduckgo.com/lite/?q=' + encodeURIComponent(val);\n"
"  fetch('/url?u=' + encodeURIComponent(url))\n"
"    .then(r => {\n"
"      notify('Searching: ' + val);\n"
"      document.getElementById('urlInput').value = '';\n"
"    })\n"
"    .catch(e => notify('Error: ' + e));\n"
"}\n"
"\n"
"function sendTextOnly() {\n"
"  const val = document.getElementById('urlInput').value;\n"
"  if (!val) return;\n"
"  fetch('/text?s=' + encodeURIComponent(val))\n"
"    .then(r => {\n"
"      notify('Sent text (' + val.length + ' chars)');\n"
"      document.getElementById('urlInput').value = '';\n"
"    })\n"
"    .catch(e => notify('Error: ' + e));\n"
"}\n"
"\n"
"const liveInput = document.getElementById('liveInput');\n"
"let lastLen = 0;\n"
"\n"
"liveInput.addEventListener('keydown', (e) => {\n"
"  if (e.key === 'Backspace') {\n"
"    sendCmd('backspace');\n"
"    e.preventDefault();\n"
"  } else if (e.key === 'Enter') {\n"
"    sendCmd('enter');\n"
"    liveInput.value = '';\n"
"    e.preventDefault();\n"
"  } else if (e.key === 'Escape') {\n"
"    sendCmd('escape');\n"
"    e.preventDefault();\n"
"  } else if (e.key === 'Tab') {\n"
"    sendCmd('tab');\n"
"    e.preventDefault();\n"
"  }\n"
"});\n"
"\n"
"liveInput.addEventListener('input', (e) => {\n"
"  if (e.data) {\n"
"    fetch('/key?c=' + encodeURIComponent(e.data))\n"
"      .then(r => notify('Key: ' + e.data))\n"
"      .catch(e => notify('Error: ' + e));\n"
"  }\n"
"  // Keep input box small\n"
"  if (liveInput.value.length > 20) liveInput.value = liveInput.value.slice(-10);\n"
"});\n"
"</script>\n"
"</body>\n"
"</html>\n";

static void handle_client(int client_fd) {
    char buf[2048];
    int n = read(client_fd, buf, sizeof(buf) - 1);
    if (n <= 0) {
        close(client_fd);
        return;
    }
    buf[n] = '\0';

    char method[16] = {0}, path[1024] = {0};
    sscanf(buf, "%15s %1023s", method, path);

    if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0) {
        char header[256];
        int content_len = strlen(HTML_PAGE);
        snprintf(header, sizeof(header),
                 "HTTP/1.1 200 OK\r\n"
                 "Content-Type: text/html; charset=UTF-8\r\n"
                 "Content-Length: %d\r\n"
                 "Connection: close\r\n\r\n", content_len);
        write(client_fd, header, strlen(header));
        write(client_fd, HTML_PAGE, content_len);
    } else if (strncmp(path, "/cmd?k=", 7) == 0) {
        char k[64] = {0};
        url_decode(k, path + 7, sizeof(k));
        char cmd[128];
        snprintf(cmd, sizeof(cmd), "KEY:%s\n", k);
        fifo_write(cmd);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
        write(client_fd, resp, strlen(resp));
    } else if (strncmp(path, "/key?c=", 7) == 0) {
        char c[32] = {0};
        url_decode(c, path + 7, sizeof(c));
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "TEXT:%s\n", c);
        fifo_write(cmd);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
        write(client_fd, resp, strlen(resp));
    } else if (strncmp(path, "/text?s=", 8) == 0) {
        char s[512] = {0};
        url_decode(s, path + 8, sizeof(s));
        char cmd[600];
        snprintf(cmd, sizeof(cmd), "TEXT:%s\n", s);
        fifo_write(cmd);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
        write(client_fd, resp, strlen(resp));
    } else if (strncmp(path, "/url?u=", 7) == 0) {
        char u[512] = {0};
        url_decode(u, path + 7, sizeof(u));
        char cmd[600];
        snprintf(cmd, sizeof(cmd), "URL:%s\n", u);
        fifo_write(cmd);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
        write(client_fd, resp, strlen(resp));
    } else if (strncmp(path, "/click?", 7) == 0) {
        int cx = 0, cy = 0;
        const char *xp = strstr(path, "x=");
        const char *yp = strstr(path, "y=");
        if (xp) cx = atoi(xp + 2);
        if (yp) cy = atoi(yp + 2);
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "CLICK:%d,%d\n", cx, cy);
        fifo_write(cmd);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
        write(client_fd, resp, strlen(resp));
    } else {
        const char *resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
        write(client_fd, resp, strlen(resp));
    }

    close(client_fd);
}

int main(void) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket failed");
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind failed");
        close(server_fd);
        return 1;
    }

    if (listen(server_fd, 8) < 0) {
        perror("listen failed");
        close(server_fd);
        return 1;
    }

    printf("[nook-webkey] Listening on port %d...\n", PORT);

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept error");
            break;
        }
        handle_client(client_fd);
    }

    close(server_fd);
    return 0;
}
