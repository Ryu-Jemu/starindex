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

/** A real Tomcat on random ports: the WebSocket handshake through the loopback filter, Redis fan-out, and both ports. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.data.redis.repositories.enabled=false",
        "starindex.pack.local-dir=build/test-packs",
        "starindex.pack.s3-bucket=",
        "management.server.port=0"})
class LiveSocketAndPortsTest extends IntegrationTestBase {

    @LocalServerPort int port;
    @LocalManagementPort int managementPort;
    @Autowired StringRedisTemplate redis;
    final HttpClient http = HttpClient.newHttpClient();

    WebSocketSession connect(BlockingQueue<String> inbox) throws Exception {
        var headers = new WebSocketHttpHeaders();
        return new StandardWebSocketClient().execute(new TextWebSocketHandler() {
            @Override
            protected void handleTextMessage(WebSocketSession s, TextMessage m) { inbox.add(m.getPayload()); }
        }, headers, URI.create("ws://127.0.0.1:" + port + "/ws/v1/live")).get(10, TimeUnit.SECONDS);
    }

    @Test
    void liveFeedGreetsForwardsRedisMessagesAndAnswersPing() throws Exception {
        BlockingQueue<String> inbox = new LinkedBlockingQueue<>();
        WebSocketSession s = connect(inbox);
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
    void serverPortServesHealthAndAdminAndManagementPortServesActuator() throws Exception {
        assertEquals(200, get("http://127.0.0.1:" + port + "/api/health").statusCode());
        assertEquals(200, get("http://[::1]:" + port + "/admin/index.html").statusCode());
        var health = get("http://127.0.0.1:" + managementPort + "/actuator/health");
        assertEquals(200, health.statusCode(), health.body());
        assertTrue(health.body().contains("\"UP\""), health.body());
    }

    HttpResponse<String> get(String url) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(url)).build(), HttpResponse.BodyHandlers.ofString());
    }
}
