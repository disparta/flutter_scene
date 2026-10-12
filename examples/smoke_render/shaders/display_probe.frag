uniform sampler2D input_color;
in vec2 v_uv;
out vec4 frag_color;
void main() { frag_color = texture(input_color, v_uv); }
