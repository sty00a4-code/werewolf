---@class HTMLElement
---@class HTMLTag
---@field id string?
---@field class string?

---@param name string
---@return fun(opts: HTMLTag): HTMLElement
local function elem(name)
    ---@param opts table
    ---@return table
    return function(opts)
        return setmetatable(opts, {
            __name = "html-element." .. name,
            __tostring = function(self)
                local keys = ""
                for k, v in pairs(self) do
                    if type(k) == "string" then
                        if v == true then
                            keys = keys .. (" %s"):format(k)
                        else
                            keys = keys .. (" %s=%q"):format(k, tostring(v))
                        end
                    end
                end
                local body = ""
                for _, v in ipairs(self) do
                    body = body .. tostring(v) .. " "
                end
                return ("<%s%s>%s</%s>"):format(name, keys, body:sub(1, #body - 1), name)
            end,
        })
    end
end
---@param name string
---@return fun(opts: HTMLTag): HTMLElement
local function void_elem(name)
    ---@param opts table
    ---@return table
    return function(opts)
        return setmetatable(opts, {
            __name = "html-element." .. name,
            __tostring = function(self)
                local keys = ""
                for k, v in pairs(self) do
                    if type(k) == "string" then
                        if v == true then
                            keys = keys .. (" %s"):format(k)
                        else
                            keys = keys .. (" %s=%q"):format(k, v)
                        end
                    end
                end
                return ("<%s%s>"):format(name, keys)
            end,
        })
    end
end

html = elem("html")
head = elem("head")
body = elem("body")

base = void_elem("base")
link = void_elem("link")
meta = void_elem("meta")
style = elem("style")
title = elem("title")

address = elem("address")
article = elem("article")
aside = elem("aside")
footer = elem("footer")
header = elem("header")
h1 = elem("h1")
h2 = elem("h2")
h3 = elem("h3")
h4 = elem("h4")
h5 = elem("h5")
h6 = elem("h6")
hgroup = elem("hgroup")
main = elem("main")
nav = elem("nav")
section = elem("section")

search = elem("search")

blockquote = elem("blockquote")
dd = elem("dd")
div = elem("div")
dl = elem("dl")
dt = elem("dt")
figcaption = elem("figcaption")
figure = elem("figure")
hr = void_elem("hr")
li = elem("li")
menu = elem("menu")
ol = elem("ol")
p = elem("p")
pre = elem("pre")
ul = elem("ul")

a = elem("a")
abbr = elem("abbr")
b = elem("b")
bdi = elem("bdi")
bdo = elem("bdo")
br = void_elem("br")
cite = elem("cite")
code = elem("code")
data = elem("data")
dfn = elem("dfn")
em = elem("em")
i = elem("i")
kbd = elem("kbd")
mark = elem("mark")
q = elem("q")
rp = elem("rp")
rt = elem("rt")
ruby = elem("ruby")
s = elem("s")
samp = elem("samp")
small = elem("small")
span = elem("span")
strong = elem("strong")
sub = elem("sub")
sup = elem("sup")
time = elem("time")
u = elem("u")
var = elem("var")
wbr = void_elem("wbr")

area = void_elem("area")
audio = elem("audio")
img = void_elem("img")
map = elem("map")
track = void_elem("track")
video = elem("video")

embed = void_elem("embed")
fencedframe = elem("fencedframe")
iframe = elem("iframe")
object = elem("object")
picture = elem("picture")
source = void_elem("source")

svg = elem("svg")
_math = elem("math")

canvas = elem("canvas")
noscript = elem("noscript")
script = elem("script")

del = elem("del")
ins = elem("ins")

caption = elem("caption")
col = void_elem("col")
colgroup = elem("colgroup")
_table = elem("table")
tbody = elem("tbody")
td = elem("td")
tfoot = elem("tfoot")
th = elem("th")
thead = elem("thead")
tr = elem("tr")

button = elem("button")
datalist = elem("datalist")
fieldset = elem("fieldset")
form = elem("form")
input = void_elem("input")
label = elem("label")
legend = elem("legend")
meter = elem("meter")
optgroup = elem("optgroup")
option = elem("option")
output = elem("output")
progress = elem("progress")
select = elem("select")
textarea = elem("textarea")

textarea = elem("textarea")
selectedcontent = elem("selectedcontent")

formelement = elem("output") -- alias

command = void_elem("command")
keygen = void_elem("keygen")
param = void_elem("param")
font = elem("font")
canvas = elem("canvas")
slot = elem("slot")
noscript = elem("noscript")
