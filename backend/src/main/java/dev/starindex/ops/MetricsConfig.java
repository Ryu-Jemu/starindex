package dev.starindex.ops;

import dev.starindex.pack.PackStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.cloudwatch.CloudWatchClient;
import software.amazon.awssdk.services.cloudwatch.model.MetricDatum;
import software.amazon.awssdk.services.cloudwatch.model.StandardUnit;

import java.time.Instant;

/**
 * Sends {@code StarIndex/PackAgeMinutes} every 5 minutes from the long-running server (METRICS_ENABLED=true on EC2).
 * One custom metric and ~8,900 PutMetricData calls a month stay in the CloudWatch free tier (PLAN 3.6).
 */
@Configuration
@EnableScheduling
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@ConditionalOnProperty(name = "starindex.metrics.enabled", havingValue = "true")
public class MetricsConfig {
    private final PackAgeMetric metric;

    public MetricsConfig(PackStore store, @Value("${starindex.metrics.region:ap-northeast-2}") String region) {
        CloudWatchClient cw = CloudWatchClient.builder().region(Region.of(region)).httpClient(UrlConnectionHttpClient.create()).build();
        this.metric = new PackAgeMetric(store, (ns, name, value) -> cw.putMetricData(r -> r.namespace(ns)
                .metricData(MetricDatum.builder().metricName(name).value(value).unit(StandardUnit.NONE).timestamp(Instant.now()).build())));
    }

    @Bean
    PackAgeMetric packAgeMetric() { return metric; }

    @Scheduled(fixedRate = 300_000, initialDelay = 60_000)
    void publishPackAge() { metric.publish(Instant.now()); }
}
