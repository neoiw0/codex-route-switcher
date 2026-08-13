# -*- coding: utf-8 -*-
# codex-opencode-pro-bridge.py
# OpenCode Go 网关的 deepseek-v4-pro 路由对消息格式要求过严（每条输入必须带
# id、assistant content 为字符串、function_call 需转 tool_calls 且后跟 tool
# 消息），Codex 原生的 Responses 格式会被 400 拒绝。这个本地小桥把 Codex 的
# Responses 请求转换成网关能接受的 chat 风格（自动补 id），并把网关返回的
# 残缺 SSE 流补成 Codex 需要的标准事件（response.created / output_item.added
# / output_text.delta / output_item.done 等，且每条 data 都带 type 字段）。
#
# 用法: python codex-opencode-pro-bridge.py [port]   (默认 9877)
# 只监听 127.0.0.1；不含任何密钥，Authorization 原样转发。
# 日志只记录模型名/条数/错误，不记录对话内容，也不落盘请求正文。

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

TARGET = "https://opencode.ai/zen/go"
LOG = os.path.join(os.environ.get("TEMP", "."), "codex-opencode-pro-bridge.log")
BODYCAPTURE = os.environ.get("CODEX_BODY_CAPTURE", "")  # 诊断用：落盘请求正文（默认关）
SSEDUMP = os.environ.get("CODEX_SSE_DUMP", "")  # 诊断用：落盘转发的 SSE 流（默认关）
KEEP_TOOLS = os.environ.get("CODEX_KEEP_TOOLS", "") == "1"  # 诊断/CLI 用：保留工具
LOCK = threading.Lock()


def log_rec(rec):
    try:
        with LOCK:
            with open(LOG, "ab") as f:
                f.write(json.dumps(rec, ensure_ascii=False).encode("utf-8") + b"\n")
    except Exception:
        pass


def capture_bytes(path, data):
    try:
        with LOCK:
            with open(path, "ab") as f:
                f.write(data)
    except Exception:
        pass


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for p in content:
            if isinstance(p, dict):
                if p.get("type") in ("input_text", "output_text", "text"):
                    parts.append(p.get("text", ""))
                elif p.get("type") == "refusal":
                    parts.append(p.get("refusal", ""))
        return "\n".join(parts)
    return ""


def convert_input(items):
    # Responses 输入 -> chat 风格（补 id；连续 function_call 合并为一条
    # assistant.tool_calls；配对修正：去掉没有对应 tool 消息的 tool_calls；
    # reasoning 项合并进下一条 assistant 消息的 reasoning_content 传回；
    # 工具结果（role:"tool"）转成 role:"user"（网关不认 tool 角色）。
    out = []
    pending_reasoning = []

    def attach_reasoning(msg):
        if pending_reasoning:
            msg["reasoning_content"] = "\n".join(pending_reasoning)
            del pending_reasoning[:]
        return msg

    for it in items or []:
        t = it.get("type")
        if t is None:
            out.append(it)  # 已经是 chat 风格，原样保留
            continue
        if t == "reasoning":
            for c in it.get("content") or []:
                if isinstance(c, dict) and c.get("text"):
                    pending_reasoning.append(c["text"])
            continue
        if t == "message":
            role = it.get("role", "user")
            msg = {"role": role, "content": text_of(it.get("content"))}
            if role == "assistant":
                attach_reasoning(msg)
            out.append(msg)
        elif t == "function_call":
            call_id = it.get("id") or it.get("call_id") or ("call_%d" % len(out))
            tc = {
                "id": call_id,
                "type": "function",
                "function": {"name": it.get("name", ""), "arguments": it.get("arguments", "{}")},
            }
            if out and out[-1].get("role") == "assistant" and out[-1].get("tool_calls") is not None and out[-1].get("content") == "":
                out[-1]["tool_calls"].append(tc)
            else:
                out.append(attach_reasoning({"role": "assistant", "content": "", "tool_calls": [tc]}))
        elif t == "function_call_output":
            call_id = it.get("call_id", "")
            out.append({"role": "user", "content": "[Tool output for %s]\n%s" % (call_id, text_of(it.get("output")))})
        elif t == "custom_tool_call":
            call_id = it.get("id") or it.get("call_id") or ("call_%d" % len(out))
            tc = {
                "id": call_id,
                "type": "function",
                "function": {"name": it.get("name", "apply_patch"), "arguments": json.dumps({"input": it.get("input", "")})},
            }
            if out and out[-1].get("role") == "assistant" and out[-1].get("tool_calls") is not None and out[-1].get("content") == "":
                out[-1]["tool_calls"].append(tc)
            else:
                out.append(attach_reasoning({"role": "assistant", "content": "", "tool_calls": [tc]}))
        elif t == "custom_tool_call_output":
            call_id = it.get("call_id", "")
            out.append({"role": "user", "content": "[Tool output for %s]\n%s" % (call_id, text_of(it.get("output")))})
        # web_search_call 等不进入 chat 载荷

    if pending_reasoning:
        # 最后仍有未附着的 reasoning（极端情况），丢弃，避免生成孤立消息
        del pending_reasoning[:]

    fixed = []
    pending_ids = set()
    for msg in out:
        if msg.get("role") == "assistant" and msg.get("tool_calls"):
            pending_ids = {tc["id"] for tc in msg["tool_calls"]}
            fixed.append(msg)
        elif msg.get("role") == "user" and msg.get("content", "").startswith("[Tool output for "):
            # 工具结果已转为 user 消息，直接保留（不再参与配对）
            fixed.append(msg)
            m = re.match(r"\[Tool output for ([^\]]+)\]", msg.get("content", ""))
            if m:
                pending_ids.discard(m.group(1))
        else:
            # 真实 user/assistant 消息到来时，若上一轮 tool_calls 还没结果，
            # 视为孤儿调用，从最后的 assistant 消息里移除
            if pending_ids:
                for prev in reversed(fixed):
                    if prev.get("role") == "assistant" and prev.get("tool_calls"):
                        prev["tool_calls"] = [tc for tc in prev["tool_calls"] if tc["id"] not in pending_ids]
                        if not prev["tool_calls"]:
                            prev.pop("tool_calls")
                            prev["content"] = ""
                        break
                pending_ids = set()
            fixed.append(msg)
    if pending_ids:
        for prev in reversed(fixed):
            if prev.get("role") == "assistant" and prev.get("tool_calls"):
                prev["tool_calls"] = [tc for tc in prev["tool_calls"] if tc["id"] not in pending_ids]
                if not prev["tool_calls"]:
                    prev.pop("tool_calls")
                    prev["content"] = ""
                break
    return fixed


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _models(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(MODELS_BODY)))
        self.end_headers()
        self.wfile.write(MODELS_BODY)

    def do_GET(self):
        log_rec({"method": "GET", "path": self.path, "upgrade": self.headers.get("Upgrade")})
        if self.path.startswith("/v1/models"):
            self._models()
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        forwarded = body
        parsed = None
        try:
            parsed = json.loads(body.decode("utf-8"))
            if isinstance(parsed, dict) and isinstance(parsed.get("input"), list):
                parsed["input"] = convert_input(parsed["input"])
                if not KEEP_TOOLS and parsed.get("tools"):
                    # OpenCode Pro 在桌面版里一旦模型调用工具，应用会在工具轮后
                    # 卡死（应用内部行为，无法修复）。默认去掉工具，让 Pro 以
                    # 纯对话模式稳定运行；flash / DeepSeek 官方不受影响。
                    tool_count = len(parsed["tools"])
                    parsed.pop("tools", None)
                    parsed.pop("tool_choice", None)
                    parsed.pop("parallel_tool_calls", None)
                    log_rec({"tools_stripped": tool_count})
                forwarded = json.dumps(parsed, ensure_ascii=False).encode("utf-8")
        except Exception as exc:
            log_rec({"parse_error": str(exc)})

        rec = {"method": "POST", "path": self.path}
        if isinstance(parsed, dict):
            rec["model"] = parsed.get("model")
            rec["input_count"] = len(parsed.get("input", []))
        log_rec(rec)

        req = Request(TARGET + self.path, data=forwarded, method="POST")
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "accept-encoding"):
                req.add_header(k, v)
        try:
            if BODYCAPTURE:
                capture_bytes(BODYCAPTURE, b"==== REQUEST ====\n" + forwarded + b"\n\n")
            resp = urlopen(req, timeout=600)
            if BODYCAPTURE:
                capture_bytes(BODYCAPTURE, b"==== UPSTREAM STATUS " + str(resp.status).encode() + b" ====\n")
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(k, v)
            self.end_headers()
            self._relay_stream(resp)
        except HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")
            log_rec({"upstream_error": exc.code, "body": err_body[:500]})
            if BODYCAPTURE:
                capture_bytes(BODYCAPTURE, ("==== UPSTREAM ERROR %d ====\n%s\n\n" % (exc.code, err_body)).encode("utf-8"))
            try:
                self.send_response(exc.code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(err_body.encode("utf-8"))
            except Exception:
                pass
        except Exception as exc:
            log_rec({"forward_error": str(exc)})
            try:
                self.send_response(502)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(str(exc).encode())
            except Exception:
                pass

    def _relay_stream(self, resp):
        buf = b""
        self._state = {"items": {}, "text_item": None, "next_index": 0, "seq": 0, "seq_base": -1, "response": None}
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                self._process_block(block)
        if buf.strip():
            self._process_block(buf)
        self._flush_all(final=True)

    def _emit(self, event, data_obj):
        data_obj = dict(data_obj)
        data_obj.setdefault("type", event)  # Codex 要求每条 SSE data 带顶层 type
        # 合成事件的序号接在上游最大序号之后，避免与上游事件混流时序号回退
        data_obj.setdefault("sequence_number", self._state["seq_base"] + self._state["seq"] + 1)
        self._state["seq"] += 1
        line = "event: %s\ndata: %s\n\n" % (event, json.dumps(data_obj, ensure_ascii=False))
        self.wfile.write(line.encode("utf-8"))
        self.wfile.flush()
        if SSEDUMP:
            capture_bytes(SSEDUMP, line.encode("utf-8"))

    def _write_raw(self, block):
        data = block + b"\n\n"
        self.wfile.write(data)
        self.wfile.flush()
        if SSEDUMP:
            capture_bytes(SSEDUMP, data)

    def _process_block(self, block):
        lines = block.decode("utf-8", errors="replace").split("\n")
        event = ""
        data_lines = []
        for ln in lines:
            if ln.startswith("event:"):
                event = ln[6:].strip()
            elif ln.startswith("data:"):
                data_lines.append(ln[5:].strip())
        data_str = "\n".join(data_lines)
        state = self._state
        try:
            seq = json.loads(data_str).get("sequence_number")
            if isinstance(seq, int) and seq >= 0:
                state["seq_base"] = max(state["seq_base"], seq)
        except Exception:
            pass
        if event == "response.output_text.delta":
            try:
                d = json.loads(data_str)
            except Exception:
                self._write_raw(block)
                return
            if state["response"] is None:
                self._emit_created(d)
            item_id = d.get("item_id") or d.get("id") or (d.get("response") or {}).get("id") or "item_%d" % state["next_index"]
            delta = d.get("delta", "")
            ti = state["text_item"]
            if ti is None or ti["id"] != item_id:
                self._flush_text_item()
                idx = state["next_index"]
                state["next_index"] += 1
                ti = {"id": item_id, "output_index": idx, "content_index": 0, "text": ""}
                state["text_item"] = ti
                self._emit(
                    "response.output_item.added",
                    {
                        "output_index": idx,
                        "item": {
                            "id": item_id,
                            "type": "message",
                            "status": "in_progress",
                            "role": "assistant",
                            "phase": "final_answer",
                            "content": [],
                        },
                    },
                )
                self._emit(
                    "response.content_part.added",
                    {
                        "item_id": item_id,
                        "output_index": idx,
                        "content_index": 0,
                        "part": {"type": "output_text", "text": "", "annotations": [], "logprobs": []},
                    },
                )
            ti["text"] += delta
            self._emit(
                "response.output_text.delta",
                {"item_id": item_id, "output_index": ti["output_index"], "content_index": 0, "delta": delta, "logprobs": []},
            )
        elif event == "response.output_item.added":
            try:
                d = json.loads(data_str)
                it = d.get("item", {})
                if it.get("type") == "function_call":
                    idx = d.get("output_index", state["next_index"])
                    state["next_index"] = max(state["next_index"], idx + 1)
                    state["items"][idx] = {"item": it, "args": ""}
                elif it.get("type") == "message":
                    # 上游把长回复拆成很多个独立 message item 逐块发送，
                    # 原样透传会让 Codex 桌面版界面卡死；这里吞掉，
                    # 由下面合成的单条 message 生命周期替代。
                    return
            except Exception:
                pass
            self._write_raw(block)
        elif event == "response.function_call_arguments.delta":
            try:
                d = json.loads(data_str)
                idx = d.get("output_index")
                if idx in state["items"]:
                    state["items"][idx]["args"] += d.get("delta", "")
            except Exception:
                pass
            self._write_raw(block)
        elif event in ("response.output_item.done", "response.content_part.added",
                       "response.content_part.done", "response.output_text.done"):
            # message/function_call 的 done 由合成/冲刷逻辑统一发出；
            # content_part/output_text 的结束事件应用侧不处理，一并吞掉。
            # reasoning 的 output_item.done 仍会原样透传。
            if event == "response.output_item.done":
                try:
                    d = json.loads(data_str)
                    it = d.get("item", {})
                    if it.get("type") in ("message", "function_call"):
                        return
                except Exception:
                    pass
                self._write_raw(block)
            else:
                return
        elif event == "response.completed":
            self._flush_text_item()
            self._flush_function_calls()
            try:
                d = json.loads(data_str)
                d.setdefault("type", "response.completed")
                r = d.get("response") or {}
                r.setdefault("status", "completed")
                r.setdefault("object", "response")
                d["response"] = r
                self._write_raw("event: response.completed\ndata: " + json.dumps(d, ensure_ascii=False))
            except Exception:
                self._write_raw(block)
        else:
            self._write_raw(block)

    def _emit_created(self, first_delta):
        r = (first_delta.get("response") or {})
        rid = r.get("id") or ("resp_%d" % int(time.time() * 1000))
        resp = {
            "id": rid,
            "object": "response",
            "created_at": int(time.time()),
            "completed_at": None,
            "status": "in_progress",
            "model": r.get("model", "deepseek-v4-pro"),
        }
        self._state["response"] = resp
        self._emit("response.created", {"response": resp})
        self._emit("response.in_progress", {"response": resp})

    def _flush_text_item(self):
        ti = self._state["text_item"]
        if ti is None:
            return
        self._state["text_item"] = None
        self._emit(
            "response.output_text.done",
            {"item_id": ti["id"], "output_index": ti["output_index"], "content_index": 0, "text": ti["text"], "logprobs": []},
        )
        self._emit(
            "response.content_part.done",
            {
                "item_id": ti["id"],
                "output_index": ti["output_index"],
                "content_index": 0,
                "part": {"type": "output_text", "text": ti["text"], "annotations": [], "logprobs": []},
            },
        )
        self._emit(
            "response.output_item.done",
            {
                "output_index": ti["output_index"],
                "item": {
                    "id": ti["id"],
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "phase": "final_answer",
                    "content": [{"type": "output_text", "text": ti["text"], "annotations": [], "logprobs": []}],
                },
            },
        )

    def _flush_function_calls(self):
        for idx in sorted(self._state["items"].keys()):
            rec = self._state["items"][idx]
            item = dict(rec["item"])
            item["status"] = "completed"
            item["arguments"] = rec["args"]
            self._emit(
                "response.function_call_arguments.done",
                {"item_id": item.get("id"), "output_index": idx, "arguments": rec["args"]},
            )
            self._emit("response.output_item.done", {"output_index": idx, "item": item})
        self._state["items"] = {}

    def _flush_all(self, final=False):
        self._flush_text_item()
        self._flush_function_calls()

    def log_message(self, fmt, *args):
        pass


MODELS_BODY = json.dumps(
    {"object": "list", "data": [{"id": "deepseek-v4-pro", "object": "model", "owned_by": "opencode"}]},
    ensure_ascii=False,
).encode("utf-8")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9877
    log_rec({"bridge_start": True, "port": port, "target": TARGET})
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
