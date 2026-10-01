package dev.starindex.ws;

import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

import java.nio.charset.StandardCharsets;

/**
 * {@code /ws/v1/live} behind CloudFront (PLAN 3.4 WebSocket). Redis Pub/Sub {@code ch:live} fans out pack
 * notifications from whichever JVM published (the server's scheduler or a CLI run via scripts/etl.sh).
 * Native apps send no Origin header and are accepted; browsers on other origins are refused (Spring's default).
 */
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@Configuration
@EnableWebSocket
@EnableScheduling
public class LiveSocketConfig implements WebSocketConfigurer {
    public static final String CHANNEL = "ch:live";

    private final LiveSocketHandler handler;

    public LiveSocketConfig(StringRedisTemplate redis, @Value("${starindex.ws.max-sessions:500}") int maxSessions) {
        this.handler = new LiveSocketHandler(redis, maxSessions);
    }

    @Bean
    LiveSocketHandler liveSocketHandler() { return handler; }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/ws/v1/live");
    }

    @Scheduled(fixedRate = 60_000, initialDelay = 60_000)
    void sweepLiveSessions() { handler.sweep(); }

    @Bean
    RedisMessageListenerContainer liveChannelListener(RedisConnectionFactory cf) {
        var c = new RedisMessageListenerContainer();
        c.setConnectionFactory(cf);
        c.addMessageListener((message, pattern) -> handler.broadcast(new String(message.getBody(), StandardCharsets.UTF_8)),
                new ChannelTopic(CHANNEL));
        return c;
    }
}
