package dev.starindex.ws;

import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.PingMessage;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class LiveSocketHandlerTest {
    final AtomicLong now = new AtomicLong();

    @SuppressWarnings("unchecked")
    LiveSocketHandler handler(int max) {
        var redis = mock(StringRedisTemplate.class);
        ValueOperations<String, String> ops = mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(ops);
        when(ops.get("pack:manifest")).thenReturn("20261012-1700-b2a3bf8b");
        return new LiveSocketHandler(redis, max, now::get);
    }

    static WebSocketSession session(String id) {
        var s = mock(WebSocketSession.class);
        when(s.getId()).thenReturn(id);
        when(s.isOpen()).thenReturn(true);
        return s;
    }

    @Test
    void greetsWithTheLiveVersionAndLimitsInboundFrames() throws Exception {
        var h = handler(10);
        var s = session("a");
        h.afterConnectionEstablished(s);
        verify(s).sendMessage(new TextMessage("{\"type\":\"hello\",\"index\":\"20261012-1700-b2a3bf8b\"}"));
        verify(s).setTextMessageSizeLimit(1024);
    }

    @Test
    void refusesSessionsBeyondTheLimit() throws Exception {
        var h = handler(1);
        h.afterConnectionEstablished(session("a"));
        var second = session("b");
        h.afterConnectionEstablished(second);
        verify(second).close(CloseStatus.SERVICE_OVERLOAD);
        assertEquals(1, h.sessionIds().size());
    }

    @Test
    void sweepPingsLiveSessionsAndClosesSilentOnes() throws Exception {
        var h = handler(10);
        var quiet = session("quiet");
        var chatty = session("chatty");
        h.afterConnectionEstablished(quiet);
        h.afterConnectionEstablished(chatty);
        now.addAndGet(Duration.ofMinutes(2).toNanos());
        h.sweep();
        verify(quiet).sendMessage(any(PingMessage.class));
        h.handlePongMessage(chatty, new org.springframework.web.socket.PongMessage());
        now.addAndGet(Duration.ofMinutes(2).toNanos());   // quiet: 4 min silent, chatty: 2 min since its pong
        h.sweep();
        verify(quiet).close(CloseStatus.GOING_AWAY);
        verify(chatty, never()).close(any());
        assertEquals(java.util.Set.of("chatty"), h.sessionIds());
    }

    @Test
    void aFailingSessionDoesNotStopTheBroadcast() throws Exception {
        var h = handler(10);
        var broken = session("broken");
        var ok = session("ok");
        h.afterConnectionEstablished(broken);
        h.afterConnectionEstablished(ok);
        // Sessions are wrapped in ConcurrentWebSocketSessionDecorator, which delegates to the mock.
        doThrow(new java.io.IOException("reset")).when(broken).sendMessage(new TextMessage("{\"type\":\"pack\"}"));
        h.broadcast("{\"type\":\"pack\"}");
        verify(ok).sendMessage(new TextMessage("{\"type\":\"pack\"}"));
        assertTrue(h.sessionIds().contains("ok"));
    }
}
