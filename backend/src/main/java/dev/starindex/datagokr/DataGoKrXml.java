package dev.starindex.datagokr;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * One parser for every data.go.kr response we use (KMA and KASI both default to XML; XML also avoids the legacy
 * JSON pitfalls: a single item as an object, zero items as "", leading zeros lost).
 * <ul>
 *   <li>{@code <response><header><resultCode/>…</header><body><items><item>…</item></items><totalCount/>…}</li>
 *   <li>{@code <OpenAPI_ServiceResponse><cmmMsgHeader><errMsg/><returnAuthMsg/><returnReasonCode/>} (gateway errors,
 *       HTTP 4xx; JSON when the request asked for JSON)</li>
 * </ul>
 * DOCTYPE and external entities are rejected (XXE).
 */
public final class DataGoKrXml {

    public sealed interface Parsed permits GatewayError, Body {}

    public record GatewayError(String code, String errMsg, String authMsg) implements Parsed {}

    /** Items keep the raw element text (not trimmed): KASI pads times with spaces, callers normalise per field. */
    public record Body(String resultCode, String resultMsg, int totalCount, int pageNo, int numOfRows,
                       List<Map<String, String>> items) implements Parsed {
        public boolean ok() { return "00".equals(resultCode) || "0".equals(resultCode); }
        public boolean noData() { return "03".equals(resultCode); }
    }

    private static final Pattern JSON_FIELD = Pattern.compile("\"(errMsg|returnAuthMsg|returnReasonCode)\"\\s*:\\s*\"([^\"]*)\"");

    private DataGoKrXml() {}

    public static Parsed parse(byte[] bytes) {
        if (bytes == null || bytes.length == 0) throw new IllegalArgumentException("empty body");
        String head = new String(bytes, 0, Math.min(bytes.length, 64), StandardCharsets.UTF_8).stripLeading();
        if (head.startsWith("{")) return parseJsonGatewayError(new String(bytes, StandardCharsets.UTF_8));
        Document doc = secureDocument(bytes);
        Element root = doc.getDocumentElement();
        return switch (root.getTagName()) {
            case "OpenAPI_ServiceResponse" -> {
                Element h = child(root, "cmmMsgHeader");
                yield new GatewayError(text(h, "returnReasonCode"), text(h, "errMsg"), text(h, "returnAuthMsg"));
            }
            case "response" -> {
                Element header = child(root, "header");
                Element body = child(root, "body");
                List<Map<String, String>> items = new ArrayList<>();
                Element itemsEl = child(body, "items");
                if (itemsEl != null) {
                    for (Element item : children(itemsEl, "item")) {
                        Map<String, String> m = new LinkedHashMap<>();
                        for (Element f : children(item, null)) m.put(f.getTagName(), f.getTextContent());
                        items.add(Collections.unmodifiableMap(m));
                    }
                }
                yield new Body(trim(text(header, "resultCode")), trim(text(header, "resultMsg")),
                        intOr(text(body, "totalCount"), items.size()), intOr(text(body, "pageNo"), 1),
                        intOr(text(body, "numOfRows"), items.size()), List.copyOf(items));
            }
            default -> throw new IllegalArgumentException("unexpected root <" + root.getTagName() + ">");
        };
    }

    private static Parsed parseJsonGatewayError(String json) {
        if (!json.contains("OpenAPI_ServiceResponse"))
            throw new IllegalArgumentException("unexpected JSON body (the client requests XML)");
        Map<String, String> f = new LinkedHashMap<>();
        Matcher m = JSON_FIELD.matcher(json);
        while (m.find()) f.put(m.group(1), m.group(2));
        return new GatewayError(f.get("returnReasonCode"), f.get("errMsg"), f.get("returnAuthMsg"));
    }

    private static Document secureDocument(byte[] bytes) {
        try {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            f.setFeature("http://xml.org/sax/features/external-general-entities", false);
            f.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            f.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            f.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            f.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
            f.setXIncludeAware(false);
            f.setExpandEntityReferences(false);
            f.setNamespaceAware(false);
            return f.newDocumentBuilder().parse(new ByteArrayInputStream(bytes));
        } catch (Exception e) {
            throw new IllegalArgumentException("not well-formed XML: " + e.getMessage(), e);
        }
    }

    private static Element child(Element parent, String name) {
        if (parent == null) return null;
        List<Element> c = children(parent, name);
        return c.isEmpty() ? null : c.getFirst();
    }

    private static List<Element> children(Element parent, String name) {
        List<Element> out = new ArrayList<>();
        NodeList nl = parent.getChildNodes();
        for (int i = 0; i < nl.getLength(); i++) {
            Node n = nl.item(i);
            if (n instanceof Element e && (name == null || name.equals(e.getTagName()))) out.add(e);
        }
        return out;
    }

    private static String text(Element parent, String name) {
        Element e = child(parent, name);
        return e == null ? null : e.getTextContent();
    }

    private static String trim(String s) { return s == null ? null : s.strip(); }

    private static int intOr(String s, int fallback) {
        try {
            return s == null ? fallback : Integer.parseInt(s.strip());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
