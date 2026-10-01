return function(state, req, ip)
    local wolf_scale = tostring(512 / 4)
    return response {
        body = WRAPPER {
            h1 { img {
                src = "wolf.png",
                width = wolf_scale,
                height = wolf_scale
            }, "Were Wolf" },
            div {
                class = "menu",
                input {
                    id = "name",
                    type = "text",
                    placeholder = "ENTER NAME",
                },
                div {
                    class = "input-row",
                    input {
                        id = "code",
                        type = "text",
                        placeholder = "ENTER CODE",
                        pattern = "[A-Z]*",
                        minlength = 8,
                        maxlength = 8,
                        title = "only uppercase letters A-Z",
                        oninput = [[this.value = this.value.toUpperCase().replace(/[^A-Z]/g, '');]]
                    },
                    button {
                        id = "joinGame", "JOIN",
                        onclick = "join()",
                    }
                },
                button {
                    id = "createGame",
                    onclick = "window.location.href = '/create';",
                    "CREATE GAME"
                }
            },
            script { [[
                async function join() {
                    const code = document.getElementById('code').value;
                    const name = document.getElementById('name').value.trim();
                    if (code.length != 8) {
                        alert('code must be 8 characters long');
                        return;
                    }
                    if (name.length == 0) {
                        alert('enter a name first');
                        return;
                    }
                    const r = await fetch('/api/join?code=' + code + '&name=' + encodeURIComponent(name), { method: 'POST' });
                    const text = await r.text();
                    if (!r.ok) { alert(text); return; }
                    window.location.href = '/client?code=' + code + '&token=' + text;
                }
            ]] },
        }
    }
end
