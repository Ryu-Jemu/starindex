#!/usr/bin/env python3
"""data.go.kr stand-in for scripts/ec2sim.sh (DB-PLAN 6.2).

Answers the five APIs the ETL calls with fixed, well-formed XML in the shapes of backend/src/test/.../Fixtures.java,
so the jobs run end to end without a service key. Listens on 127.0.0.1 only.
    python3 scripts/ec2sim_stub.py 18089
"""
import datetime as dt
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HEAD = '<?xml version="1.0" encoding="UTF-8"?><response><header><resultCode>00</resultCode><resultMsg>NORMAL SERVICE.</resultMsg></header><body><items>'


def body(items, total):
    return HEAD + "".join(items) + f"</items><numOfRows>1000</numOfRows><pageNo>1</pageNo><totalCount>{total}</totalCount></body></response>"


def kma(q):
    base = dt.datetime.strptime(q["base_date"] + q["base_time"], "%Y%m%d%H%M")
    rows = []
    for h in range(1, 61):  # 60 hourly slots after the issue, 7 items each (like Fixtures.kmaHours)
        t = base + dt.timedelta(hours=h)
        d, tm = t.strftime("%Y%m%d"), t.strftime("%H00")
        for cat, val in (("SKY", "3" if h % 5 == 0 else "1"), ("PTY", "0"), ("TMP", "14"), ("REH", "85"),
                         ("WSD", "1.8"), ("POP", "10"), ("PCP", "강수없음")):
            rows.append(f"<item><baseDate>{q['base_date']}</baseDate><baseTime>{q['base_time']}</baseTime><category>{cat}</category>"
                        f"<fcstDate>{d}</fcstDate><fcstTime>{tm}</fcstTime><fcstValue>{val}</fcstValue>"
                        f"<nx>{q['nx']}</nx><ny>{q['ny']}</ny></item>")
    return body(rows, len(rows))


def riseset(q):
    return body([f"<item><aste>1943  </aste><astm>0436  </astm><civile>1845  </civile><civilm>0559  </civilm>"
                 f"<latitudeNum>{q['latitude']}</latitudeNum><location>ec2sim</location><locdate>{q['locdate']}</locdate>"
                 f"<longitudeNum>{q['longitude']}</longitudeNum><moonrise>1925  </moonrise><moonset>0904  </moonset>"
                 f"<moontransit>------</moontransit><naute>1914  </naute><nautm>0530  </nautm><sunrise>0625  </sunrise>"
                 f"<sunset>1819  </sunset><suntransit>122245</suntransit></item>"], 1)


def month(q, items):
    return body([i.replace("YYYYMM", q["solYear"] + q["solMonth"]) for i in items], len(items))


EVENTS = ["<item><astroEvent>이달의 천문 이야기</astroEvent><astroTitle>ec2sim</astroTitle><locdate>YYYYMM</locdate><seq>1</seq></item>",
          "<item><astroEvent>보름(망)</astroEvent><astroTitle>13:53</astroTitle><locdate>YYYYMM26</locdate><remarks/><seq>1</seq></item>"]
REST = ["<item><dateKind>01</dateKind><dateName>ec2sim</dateName><isHoliday>Y</isHoliday><locdate>YYYYMM03</locdate><seq>1</seq></item>"]
DIVISIONS = ["<item><dateKind>03</dateKind><dateName>ec2sim</dateName><isHoliday>N</isHoliday><kst>0541 </kst><locdate>YYYYMM08</locdate><seq>1</seq><sunLongitude>195</sunLongitude></item>"]
LUNAR = ["<item><lunDay>21</lunDay><lunIljin>갑자(甲子)</lunIljin><lunLeapmonth>평</lunLeapmonth><lunMonth>08</lunMonth><lunNday>30</lunNday><lunYear>2026</lunYear><solDay>01</solDay><solJd>2461315</solJd><solLeapyear>평</solLeapyear><solMonth>10</solMonth><solWeek>목</solWeek><solYear>2026</solYear></item>"]

ROUTES = {
    "/1360000/VilageFcstInfoService_2.0/getVilageFcst": kma,
    "/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo": riseset,
    "/B090041/openapi/service/AstroEventInfoService/getAstroEventInfo": lambda q: month(q, EVENTS),
    "/B090041/openapi/service/SpcdeInfoService/getRestDeInfo": lambda q: month(q, REST),
    "/B090041/openapi/service/SpcdeInfoService/get24DivisionsInfo": lambda q: month(q, DIVISIONS),
    "/B090041/openapi/service/LrsrCldInfoService/getLunCalInfo": lambda q: month(q, LUNAR),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        route = ROUTES.get(u.path)
        if route is None:
            self.send_error(404)
            return
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        data = route(q).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/xml;charset=UTF-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 18089), Handler).serve_forever()
