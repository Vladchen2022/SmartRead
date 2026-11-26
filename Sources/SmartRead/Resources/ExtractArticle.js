const template = document.createElement("template");
template.innerHTML = html;
const fragment = template.content;

// The source stays in an inert template. Strip executable and resource-loading elements before
// moving any of its nodes into a detached document used by Readability.
const sourceTitle = fragment.querySelector('meta[property="og:title"]')?.content
    || fragment.querySelector("title")?.textContent || "";
const sourceDescription = fragment.querySelector('meta[property="og:description"]')?.content || "";
fragment.querySelectorAll("script, style, noscript, template, iframe, frame, link, base, img, svg, object, embed, audio, video, source, track, input").forEach(node => node.remove());

const doc = document.implementation.createHTMLDocument(sourceTitle);
const base = doc.createElement("base");
base.href = sourceURL;
doc.head.append(base);
fragment.querySelectorAll("meta").forEach(node => {
    if (node.hasAttribute("http-equiv")) node.remove();
    else doc.head.append(node);
});
fragment.querySelectorAll("title").forEach(node => node.remove());
doc.body.append(fragment);

function plainText(root) {
    const paragraphs = [];
    let line = "";
    const blocks = new Set(["P", "DIV", "ARTICLE", "SECTION", "H1", "H2", "H3", "H4",
        "H5", "H6", "LI", "BLOCKQUOTE", "PRE", "FIGCAPTION", "TR"]);

    function flush() {
        const text = line.replace(/[\t\f\r\n ]+/g, " ").trim();
        if (text) paragraphs.push(text);
        line = "";
    }

    function visit(node) {
        if (node.nodeType === Node.TEXT_NODE) {
            line += node.nodeValue;
            return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return;
        if (node.tagName === "BR") {
            flush();
            return;
        }
        if (node.hidden || node.getAttribute("aria-hidden") === "true") return;
        const block = blocks.has(node.tagName);
        if (block) flush();
        if (node.tagName === "LI") line += "• ";
        node.childNodes.forEach(visit);
        if (block) flush();
        if (node.tagName === "TD" || node.tagName === "TH") line += " ";
    }

    visit(root);
    return paragraphs.join("\n\n");
}

if (mode === "x-embed") {
    const post = doc.querySelector("blockquote.twitter-tweet p");
    const title = "X 帖子";
    const body = post?.textContent.trim() || "";
    if (!body || /^https?:\/\/\S+$/.test(body) || /(?:…|\.\.\.)\s*(?:https?:\/\/\S+)?$/.test(body)) return null;
    return { title, body: plainText(post) };
}

if (mode === "x") {
    const article = doc.querySelector("[data-article-body-html], .x-article-body, [data-testid='twitterArticleRichTextView']");
    if (article) {
        const heading = doc.querySelector("[data-testid='twitterArticleTitle'], h1")?.textContent.trim();
        const body = plainText(article);
        const title = heading && heading !== "X" ? heading : (sourceDescription || sourceTitle);
        if (body) return { title, body };
    }
    return null;
}

const searchDocument = doc.cloneNode(true);
const result = new Readability(searchDocument, {
    serializer: element => element
}).parse();

let body = result?.content ? plainText(result.content) : "";
if (!body) {
    const main = doc.querySelector("article, main, [role='main']");
    if (main) {
        main.querySelectorAll("nav, aside, footer, form, [role='navigation']").forEach(node => node.remove());
        body = plainText(main);
    }
}
if (body.length < 45) return null;

const title = result?.title?.trim() || sourceTitle;
if (title && body.startsWith(title + "\n\n")) body = body.slice(title.length).trimStart();
return { title, body, byline: result?.byline?.trim() || null };
