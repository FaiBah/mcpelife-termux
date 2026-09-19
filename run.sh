#!/data/data/com.termux/files/usr/bin/bash

python - <<'PY'
import os,re,sys,time,urllib.request,urllib.error
from urllib.parse import urljoin,urlparse,urlunparse,unquote
from concurrent.futures import ThreadPoolExecutor
from bs4 import BeautifulSoup

BASE="https://mcpelife.com/download/"
UA={"User-Agent":"Mozilla/5.0"}
PAGE_TIMEOUT=12
FILE_TIMEOUT=6
RETRIES=2
CACHE_TTL=600
RESOLVE_TTL=300
WORKERS=12
MAX_PAGES=100
CACHE={"time":0,"data":None}
RESOLVE_CACHE={}

class Redirect(urllib.request.HTTPRedirectHandler):
    def __init__(self):self.chain=[]
    def redirect_request(self,req,fp,code,msg,newurl):
        old=req.full_url;new=urljoin(old,newurl);self.chain.append((code,old,new,msg))
        if not safe_url(new):raise ValueError("Unsafe redirect URL")
        return super().redirect_request(req,fp,code,msg,new)

def clear():os.system("cls" if os.name=="nt" else "clear")

def safe_url(url):
    try:
        p=urlparse(url)
        return url if p.scheme in ("http","https") and p.netloc else None
    except:return None

def norm_url(url):
    u=safe_url(url)
    if not u:return None
    p=urlparse(u)
    return urlunparse((p.scheme.lower(),p.netloc.lower(),p.path or "/",p.params,p.query,""))

def req(url,headers=None,timeout=PAGE_TIMEOUT,method="GET"):
    url=norm_url(url)
    if not url:raise ValueError("Invalid or unsafe URL")
    h=UA.copy()
    if headers:h.update(headers)
    for n in range(RETRIES+1):
        rd=Redirect()
        try:
            r=urllib.request.build_opener(rd).open(urllib.request.Request(url,headers=h,method=method),timeout=timeout)
            if not safe_url(r.geturl()):r.close();raise ValueError("Unsafe redirect URL")
            r.redirect_chain=rd.chain
            return r
        except urllib.error.HTTPError as e:
            if e.code not in {429,500,502,503,504} or n>=RETRIES:raise
            try:d=float(e.headers.get("Retry-After"))
            except:d=min(2**n,10)
            time.sleep(d)
        except (urllib.error.URLError,TimeoutError,OSError):
            if n>=RETRIES:raise
            time.sleep(min(2**n,10))

def err_info(e):
    if isinstance(e,urllib.error.HTTPError):return e.code,e.reason or f"HTTP {e.code}",e.headers
    return None,str(e),{}

def soup(url):
    with req(url) as r:return BeautifulSoup(r.read(),"html.parser")

def direct(url):
    url=norm_url(url)
    if not url:raise ValueError("Invalid download URL")
    if re.search(r"\.(?:apk|ipa)(?:[?#].*)?$",url,re.I):return url
    for a in soup(url).find_all("a",href=True):
        h=norm_url(urljoin(url,a["href"]))
        if h and (re.search(r"\.(?:apk|ipa)(?:[?#].*)?$",h,re.I) or a.get_text(" ",strip=True).lower()=="download file"):return h
    raise Exception("Direct URL not found")

def filename(headers,url):
    cd=headers.get("Content-Disposition","")
    m=re.search(r"filename\*=UTF-8''([^;]+)|filename=[\"']?([^;\"']+)",cd,re.I)
    if m:return unquote(m.group(1) or m.group(2)).strip()
    return os.path.basename(urlparse(url).path) or "Unknown"

def check(url):
    url=norm_url(url)
    if not url:return {"code":None,"size":None,"type":None,"name":"Unknown","error":"Invalid or unsafe URL","redirects":[],"final":None}
    last=None
    for method,headers in [("HEAD",{"Accept-Encoding":"identity"}),("GET",{"Range":"bytes=0-0","Accept-Encoding":"identity"})]:
        try:
            with req(url,headers,FILE_TIMEOUT,method) as r:
                h=r.headers;cr=h.get("Content-Range","");m=re.search(r"bytes\s+\d+-\d+/(\d+)",cr)
                size=int(m.group(1)) if m else int(h["Content-Length"]) if h.get("Content-Length","").isdigit() else None
                return {"code":r.status,"size":size,"type":h.get("Content-Type",""),"name":filename(h,r.geturl()),"error":None,"redirects":getattr(r,"redirect_chain",[]),"final":norm_url(r.geturl())}
        except urllib.error.HTTPError as e:
            code,reason,h=err_info(e)
            last={"code":code,"size":None,"type":h.get("Content-Type",""),"name":filename(h,e.geturl()),"error":f"HTTP {code}: {reason}","redirects":[],"final":norm_url(e.geturl())}
            if code in {400,401,403,404}:return last
        except (urllib.error.URLError,TimeoutError,OSError) as e:
            last={"code":None,"size":None,"type":None,"name":"Unknown","error":"Timeout" if isinstance(e,TimeoutError) else str(e),"redirects":[],"final":url}
    return last or {"code":None,"size":None,"type":None,"name":"Unknown","error":"Request failed","redirects":[],"final":url}

def latest():
    out={}
    for a in soup(BASE).find_all("a",href=True):
        m=re.search(r"\b(Release|Beta|Preview)\s+Minecraft\s+([0-9]+(?:\.[0-9]+){1,3})\b",a.get_text(" ",strip=True),re.I)
        if not m:continue
        h=norm_url(urljoin(BASE,a["href"]))
        if not h:continue
        typ=m.group(1).lower();k="beta" if typ in {"beta","preview"} else "release"
        if k not in out:out[k]=(m.group(2),h)
    return out

def all_versions():
    if CACHE["data"] and time.time()-CACHE["time"]<CACHE_TTL:return CACHE["data"]
    stable=[];preview=[];pages=[BASE];seen=set();seenv=set();info={}
    while pages and len(seen)<MAX_PAGES:
        url=norm_url(pages.pop(0))
        if not url or url in seen:continue
        seen.add(url)
        try:links=soup(url).find_all("a",href=True)
        except Exception:continue
        for a in links:
            text=a.get_text(" ",strip=True);h=norm_url(urljoin(url,a["href"]))
            m=re.search(r"\b(Release|Beta|Preview)\s+Minecraft\s+([0-9]+(?:\.[0-9]+){1,3})\b",text,re.I)
            if m and h:
                v=m.group(2);typ="beta" if m.group(1).lower() in {"beta","preview"} else "release"
                key=(typ,v)
                if key not in seenv:
                    seenv.add(key)
                    (preview if typ=="beta" else stable).append(v)
                    info.setdefault(v,{})[typ]=h
            if re.search(r"\bNext\b",text,re.I) and h and h not in seen and h not in pages:pages.append(h)
    CACHE["time"]=time.time();CACHE["data"]=(stable,preview,info)
    return CACHE["data"]

def extract_count(text):
    for p in [r"(?:downloads?|downloaded)\s*[:\-]?\s*([\d,]+)",r"([\d,]+)\s+downloads?\b"]:
        m=re.search(p,text,re.I)
        if m:return m.group(1)
    return "Unknown"

def cards(url):
    out=[];seen=set()
    for c in soup(url).select(".newmc-file-card"):
        n=c.select_one(".newmc-file-name");a=c.select_one("a.newmc-file-download[href]")
        if not n or not a:continue
        h=norm_url(urljoin(url,a["href"]));name=n.get_text(" ",strip=True)
        if h and h not in seen:
            seen.add(h);out.append({"name":name,"page":h,"downloads":extract_count(c.get_text(" ",strip=True))})
    return out

def fmt_size(n):
    if n is None:return "Unknown"
    if n>=1024**3:return f"{n} bytes ({n/1024**3:.2f} GB)"
    if n>=1024**2:return f"{n} bytes ({n/1024**2:.2f} MB)"
    if n>=1024:return f"{n} bytes ({n/1024:.2f} KB)"
    return f"{n} bytes"

def resolve(f):
    base={**f,"url":f["page"],"final":None,"size":"Unknown","status":"failed","code":None,"type":"Unknown","realname":"Unknown","error":None,"redirects":[]}
    try:
        url=direct(f["page"]);k=norm_url(url)
        if not k:raise ValueError("Invalid or unsafe resolved URL")
        base["url"]=k;now=time.time()
        if k in RESOLVE_CACHE and now-RESOLVE_CACHE[k][0]<RESOLVE_TTL:r=RESOLVE_CACHE[k][1]
        else:r=check(k);RESOLVE_CACHE[k]=(now,r)
        base.update(code=r["code"],size=fmt_size(r["size"]),type=r["type"] or "Unknown",realname=r["name"],final=r["final"],redirects=r["redirects"],error=r["error"])
        ext=re.search(r"\.(apk|ipa)(?:[?#].*)?$",base["final"] or "",re.I);typ=(base["type"] or "").lower()
        valid=ext or any(x in typ for x in ("application/vnd.android.package-archive","application/octet-stream","application/zip"))
        base["status"]="ok" if r["code"] is not None and 200<=r["code"]<400 and valid else "failed"
        if not valid and base["status"]=="failed" and not base["error"]:base["error"]="Unexpected content type"
    except urllib.error.HTTPError as e:
        code,reason,_=err_info(e);base.update(code=code,error=f"HTTP {code}: {reason}")
    except Exception as e:base["error"]="Timeout" if isinstance(e,TimeoutError) else str(e)
    return base

def resolve_all(files):
    if not files:return []
    out=[None]*len(files);jobs={}
    with ThreadPoolExecutor(max_workers=min(WORKERS,len(files))) as pool:
        for f in files:
            k=norm_url(f["page"])
            if k and k not in jobs:jobs[k]=pool.submit(resolve,f)
        for i,f in enumerate(files):
            k=norm_url(f["page"])
            try:
                if not k:raise ValueError("Invalid or unsafe URL")
                r=jobs[k].result();out[i]={**r,"name":f["name"],"downloads":f["downloads"]}
            except KeyboardInterrupt:raise
            except Exception as e:
                out[i]={**f,"url":f["page"],"final":None,"size":"Unknown","status":"failed","code":None,"type":"Unknown","realname":"Unknown","error":str(e),"redirects":[]}
    return out

def header(title="",source=None):
    clear();print("╭────────────────────────────────────────────────────────────╮\n│  MCPELife                                                 │\n│  Minecraft Bedrock Edition                                │\n╰────────────────────────────────────────────────────────────╯")
    if title:
        print(f"\n  {title}\n  "+"─"*58)
        if source:print(f"  Source : {source}")

def pause(text="Press Enter to continue..."):input(f"\n  {text}")

def label(kind):return "Beta / Preview" if kind=="beta" else "Release"

def show_files(kind,version,page):
    name=label(kind)
    try:files=cards(page)
    except KeyboardInterrupt:raise
    except Exception as e:
        header(f"{name} • Minecraft {version}",page);print(f"\n  Page Error: {e}");pause();return
    header(f"{name} • Minecraft {version}",page);print()
    if not files:print("  No files found.");pause("Press Enter to go back...");return
    print("  Resolving download links...")
    files=resolve_all(files)
    header(f"{name} • Minecraft {version}",page);print()
    for i,f in enumerate(files,1):
        print(f"  [{i}] {f['name']}")
        print(f"      Size      : {f['size']}")
        print(f"      Downloads : {f['downloads']}")
        print(f"      Status    : {'✓ Available' if f['status']=='ok' else '✗ Failed'} ({f['code'] if f['code'] is not None else 'Unknown'}, {f['type']})")
        print(f"      Filename  : {f['realname']}")
        print(f"      URL       : {f['final'] or f['url'] or 'Unavailable'}")
        if f["redirects"]:
            print("      Redirects :")
            for code,old,new,msg in f["redirects"]:print(f"        {code}  {old} -> {new}")
        if f["status"]=="failed":print(f"      Error     : {f['error'] or 'Unknown error'}")
        print("  "+"─"*58)
        if i<len(files):print()
    pause("Press Enter to go back...")

def show(kind):
    name=label(kind)
    header(f"Loading {name}...")
    try:
        data=latest()
        if kind not in data:raise Exception("Version not found")
        v,p=data[kind];show_files(kind,v,p)
    except KeyboardInterrupt:raise
    except Exception as e:print(f"\n  Error: {e}");pause()

def version_key(v):return tuple(map(int,v.split(".")))

def major(v):
    p=v.split(".")
    return ".".join(p[:2]) if v.startswith("1.") and len(p)>1 else p[0]

def open_version(v,typ,info):
    page=info.get(v,{}).get(typ)
    if not page:page=info.get(v,{}).get("release") or info.get(v,{}).get("beta")
    if not page:
        print(f"\n  Version {v} page not found.");pause();return
    show_files(typ,v,page)

def version_select(kind,items,info):
    items=sorted(set(items),key=version_key,reverse=True)
    typ="beta" if kind.lower().startswith("beta") else "release"
    while True:
        header(f"{kind.upper()} Versions");print();groups={}
        for i,v in enumerate(items,1):groups.setdefault(major(v),[]).append((i,v))
        for m,vs in sorted(groups.items(),key=lambda x:version_key(x[0]),reverse=True):
            print(f"  ◆ MINECRAFT {m}\n  "+"─"*58)
            for i,v in vs:print(f"    [{i}] {v}")
            print()
        print("  [B] Back");c=input("\n  Select version: ").strip().lower()
        if c=="b":return
        if c.isdigit() and 1<=int(c)<=len(items):open_version(items[int(c)-1],typ,info)
        else:print("\n  Invalid selection.");pause()

def all_version_select(stable,preview,info):
    items=[("release",v) for v in stable]+[("beta",v) for v in preview]
    items.sort(key=lambda x:version_key(x[1]),reverse=True)
    while True:
        header("All Versions");print();groups={}
        for i,(typ,v) in enumerate(items,1):
            m=major(v);groups.setdefault(m,{"release":[],"beta":[]})[typ].append((i,v))
        for m,g in sorted(groups.items(),key=lambda x:version_key(x[0]),reverse=True):
            print(f"  ◆ MINECRAFT {m}\n  "+"─"*58)
            for typ,title in (("release","RELEASE"),("beta","BETA / PREVIEW")):
                if g[typ]:
                    print(f"    {title}")
                    for i,v in g[typ]:print(f"      [{i}] {v}")
                    print()
        print("  [B] Back");c=input("\n  Select version: ").strip().lower()
        if c=="b":return
        if c.isdigit() and 1<=int(c)<=len(items):
            typ,v=items[int(c)-1];open_version(v,typ,info)
        else:print("\n  Invalid selection.");pause()

def show_versions():
    header("Version List");print("\n  Loading versions...")
    try:stable,preview,info=all_versions()
    except KeyboardInterrupt:raise
    except Exception as e:print(f"\n  Error: {e}");pause();return
    while True:
        header("Version List")
        print(f"\n  [1] Release\n      {len(stable)} versions")
        print(f"\n  [2] Beta / Preview\n      {len(preview)} versions")
        print(f"\n  [3] All Versions\n      {len(stable)+len(preview)} entries")
        print("\n  [B] Back");c=input("\n  Select: ").strip().lower()
        if c=="b":return
        if c=="1":version_select("Release",stable,info)
        elif c=="2":version_select("Beta / Preview",preview,info)
        elif c=="3":all_version_select(stable,preview,info)
        else:print("\n  Invalid selection.");pause()

def custom_version():
    header("Custom Version")
    v=input("\n  Enter Minecraft version: ").strip().lower().lstrip("v")
    if not re.fullmatch(r"\d+(?:\.\d+){1,3}",v):
        print("\n  Invalid version.");pause();return
    try:
        _,_,info=all_versions()
        if v not in info:
            print(f"\n  Version {v} not found.");pause();return
        x=info[v];typ="release" if x.get("release") else "beta";open_version(v,typ,info)
    except KeyboardInterrupt:raise
    except Exception as e:print(f"\n  Error: {e}");pause()

def main():
    while True:
        header()
        print("\n  [1] Latest Release\n  [2] Latest Beta/Preview\n  [3] List Versions\n  [4] Custom Version\n\n  [Q] Quit\n")
        c=input("  Select: ").strip().lower()
        if c=="1":show("release")
        elif c=="2":show("beta")
        elif c=="3":show_versions()
        elif c=="4":custom_version()
        elif c=="q":clear();break
        else:print("\n  Invalid selection.");pause()

if __name__=="__main__":
    try:main()
    except KeyboardInterrupt:clear();sys.exit(0)
PY