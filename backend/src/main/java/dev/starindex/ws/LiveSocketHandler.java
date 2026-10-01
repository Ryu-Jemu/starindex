package dev.starindex.ws;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.PingMessage;
import org.springframework.web.socket.PongMessage;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.LongSupplier;

/**
 * Public, receive-only live feed {@code /ws/v1/live} (PLAN D10): raw JSON, no authentication, nothing about the client
 * is stored (D4). On connect the client gets {@code {"type":"hello","index":"<live pack version>"}}; afterwards every
 * message on Redis {@code ch:live} (e.g. a new pack) is forwarded as is. Text "ping" is answered with "pong" for clients
 * that cannot send protocol-level pings; anything else is ignored.
 * <p>The server pings every session each minute ({@link #sweep}) and closes one that has not answered (pong or any
 * message) for {@link #DEAD_AFTER}: a phone that lost the network leaves a half-open TCP connection that would otherwise
 * hold one of the {@code maxSessions} slots forever.
 */
public class LiveSocketHandler extends TextWebSocketHandler {
    private static final Logger log = LoggerFactory.getLogger(LiveSocketHandler.class);
    static final int SEND_TIME_LIMIT_MS = 5_000, BUFFER_LIMIT_BYTES = 64 * 1024, INBOUND_LIMIT_BYTES = 1024;
    static final Duration DEAD_AFTER = Duration.ofMinutes(3);
    private static final PingMessage PING = new PingMessage(ByteBuffer.wrap(new byte[]{'s', 'i'}));

    private final Map<String, WebSocketSession> sessions = new ConcurrentHashMap<>();
    private final Map<String, Long> lastSeen = new ConcurrentHashMap<>();
    private final StringRedisTemplate redis;
    private final int maxSessions;
    private final LongSupplier nanoClock;

    public LiveSocketHandler(StringRedisTemplate redis, int maxSessions) {
        this(redis, maxSessions, System::nanoTime);
    }

    LiveSocketHandler(StringRedisTemplate redis, int maxSessions, LongSupplier nanoClock) {
        this.redis = redis;
        this.maxSessions = maxSessions;
        this.nanoClock = nanoClock;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession raw) throws IOException {
        if (sessions.size() >= maxSessions) {
            raw.close(CloseStatus.SERVICE_OVERLOAD);
            return;
        }
        raw.setTextMessageSizeLimit(INBOUND_LIMIT_BYTES);
        raw.setBinaryMessageSizeLimit(INBOUND_LIMIT_BYTES);
        lastSeen.put(raw.getId(), nanoClock.getAsLong());
        // A slow client must not stall the broadcast loop: sends are buffered and a stuck session is closed.
        var session = new ConcurrentWebSocketSessionDecorator(raw, SEND_TIME_LIMIT_MS, BUFFER_LIMIT_BYTES,
                ConcurrentWebSocketSessionDecorator.OverflowStrategy.TERMINATE);
        sessions.put(raw.getId(), session);
        String version = null;
        try {
            version = redis.opsForValue().get("pack:manifest");
        } catch (RuntimeException e) {
            log.debug("pack:manifest unavailable: {}", e.toString());
        }
        session.sendMessage(new TextMessage(version == null ? "{\"type\":\"hello\",\"index\":null}"
                : "{\"type\":\"hello\",\"index\":\"" + version.replaceAll("[^0-9A-Za-z-]", "") + "\"}"));
    }

    @Override
    protected void handleTextMessage(WebSocketSession raw, TextMessage message) throws IOException {
        lastSeen.computeIfPresent(raw.getId(), (k, v) -> nanoClock.getAsLong());
        if ("ping".equals(message.getPayload())) {
            WebSocketSession s = sessions.get(raw.getId());
            if (s != null) s.sendMessage(new TextMessage("pong"));
        }
    }

    @Override
    protected void handlePongMessage(WebSocketSession raw, PongMessage message) {
        lastSeen.computeIfPresent(raw.getId(), (k, v) -> nanoClock.getAsLong());
    }

    @Override
    public void afterConnectionClosed(WebSocketSession raw, CloseStatus status) {
        forget(raw.getId());
    }

    @Override
    public void handleTransportError(WebSocketSession raw, Throwable exception) {
        forget(raw.getId());
    }

    private void forget(String id) {
        sessions.remove(id);
        lastSeen.remove(id);
    }

    /** Pings every session and closes the ones silent for longer than {@link #DEAD_AFTER}. */
    public void sweep() {
        long now = nanoClock.getAsLong();
        for (WebSocketSession s : sessions.values()) {
            Long seen = lastSeen.get(s.getId());
            try {
                if (seen == null || now - seen > DEAD_AFTER.toNanos() || !s.isOpen()) {
                    forget(s.getId());
                    s.close(CloseStatus.GOING_AWAY);
                } else {
                    s.sendMessage(PING);
                }
            } catch (IOException | RuntimeException e) {
                forget(s.getId());
            }
        }
    }

    /** Called for every Redis {@code ch:live} message. */
    public void broadcast(String json) {
        TextMessage msg = new TextMessage(json);
        for (WebSocketSession s : sessions.values()) {
            try {
                if (s.isOpen()) s.sendMessage(msg);
            } catch (IOException | RuntimeException e) {
                forget(s.getId());
                log.debug("live session {} dropped: {}", s.getId(), e.toString());
            }
        }
    }

    public Set<String> sessionIds() { return Set.copyOf(sessions.keySet()); }
}
