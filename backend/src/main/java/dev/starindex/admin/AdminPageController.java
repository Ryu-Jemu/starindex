package dev.starindex.admin;

import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

/** {@code http://localhost:8080/admin} on the operator's Mac → the static page (classpath:static/admin). */
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@Controller
public class AdminPageController {
    @GetMapping({"/admin", "/admin/"})
    public String page() {
        return "forward:/admin/index.html";
    }
}
