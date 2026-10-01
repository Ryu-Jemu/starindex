package dev.starindex.web;

import dev.starindex.IntegrationTestBase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketHttpHeaders;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.client.standard.StandardWebSocketClient;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** A real Tomcat on random ports: the WebSocket handshake through the origin filter, Redis fan-out, and both ports. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.data.redis.repositories.enabled=false",
        "starindex.pack.local-dir=build/test-packs",
        "management.server.port=0",
        "starindex.security.origin-verify-secret=" + LiveSocketAndPortsTest.SECRET})
class LiveSocketAndPortsTest extends IntegrationTestBase {
    static final String SECRET = "ws-test-origin-secret-0123456789abcdef";

    @LocalServerPort int port;
    @LocalManagementPort int managementPort;
    @Autowired StringRedisTemplate redis;
    final HttpClient http = HttpClient.newHttpClient();

    WebSocketSession connect(BlockingQueue<String> inbox, String originSecret) throws Exception {
        var headers = new WebSocketHttpHeaders();
        if (originSecret != null) headers.add("X-Origin-Verify", originSecret);
        return new StandardWebSocketClient().execute(new TextWebSocketHandler() {
            @Override
            protected void handleTextMessage(WebSocketSession s, TextMessage m) { inbox.add(m.getPayload()); }
        }, headers, URI.create("ws://127.0.0.1:" + port + "/ws/v1/live")).get(10, TimeUnit.SECONDS);
    }

    @Test
    void liveFeedGreetsForwardsRedisMessagesAndAnswersPing() throws Exception {
        BlockingQueue<String> inbox = new LinkedBlockingQueue<>();
        WebSocketSession s = connect(inbox, SECRET);   // as CloudFront would forward it
        try {
            String hello = inbox.poll(5, TimeUnit.SECONDS);
            assertNotNull(hello);
            assertTrue(hello.startsWith("{\"type\":\"hello\""), hello);
            redis.convertAndSend("ch:live", "{\"type\":\"pack\",\"kind\":\"index\",\"version\":\"v-test\"}");
            assertEquals("{\"type\":\"pack\",\"kind\":\"index\",\"version\":\"v-test\"}", inbox.poll(5, TimeUnit.SECONDS));
            s.sendMessage(new TextMessage("ping"));
            assertEquals("pong", inbox.poll(5, TimeUnit.SECONDS));
        } finally {
            s.close();
        }
    }

    @Test
    void handshakeWithAWrongOriginSecretIsRefused() {
        var e = assertThrows(Exception.class, () -> connect(new LinkedBlockingQueue<>(), "wrong-secret"));
        assertTrue(String.valueOf(e).contains("403") || String.valueOf(e.getCause()).contains("403"), e.toString());
    }

    @Test
    void publicPortServesHealthAndManagementPortIsLoopbackOnly() throws Exception {
        assertEquals(200, get("http://127.0.0.1:" + port + "/api/health", null).statusCode());
        assertEquals(403, get("http://127.0.0.1:" + port + "/admin/index.html", SECRET).statusCode());
        var health = get("http://127.0.0.1:" + managementPort + "/actuator/health", null);
        assertEquals(200, health.statusCode(), health.body());
        assertTrue(health.body().contains("\"UP\""), health.body());
    }

    HttpResponse<String> get(String url, String originSecret) throws Exception {
        var b = HttpRequest.newBuilder(URI.create(url));
        if (originSecret != null) b.header("X-Origin-Verify", originSecret);
        return http.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }
}
