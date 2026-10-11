// Deterministic GPU fixture comparison. No third-party test dependencies.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>
std::string read(const char* p) { std::ifstream f(p); std::stringstream s; s<<f.rdbuf(); return s.str(); }
GLuint shader(GLenum type, const std::string& s) {
  auto id=glCreateShader(type); const char* p=s.c_str(); glShaderSource(id,1,&p,nullptr); glCompileShader(id);
  GLint ok; glGetShaderiv(id,GL_COMPILE_STATUS,&ok); if(!ok) { char log[8192];glGetShaderInfoLog(id,8192,nullptr,log);throw std::runtime_error(log); } return id;
}
GLuint program(const char* p) {
  auto id=glCreateProgram(); glAttachShader(id,shader(GL_VERTEX_SHADER,
    "#version 410 core\nin vec2 position; out vec2 v_uv; void main(){v_uv=position*0.5+0.5;gl_Position=vec4(position,0,1);}"));
  glAttachShader(id,shader(GL_FRAGMENT_SHADER,read(p)));glBindAttribLocation(id,0,"position");glLinkProgram(id);
  GLint ok;glGetProgramiv(id,GL_LINK_STATUS,&ok);if(!ok){char log[8192];glGetProgramInfoLog(id,8192,nullptr,log);throw std::runtime_error(log);}return id;
}
GLuint texture(int w,int h,const float* pixels) {
  GLuint t;glGenTextures(1,&t);glBindTexture(GL_TEXTURE_2D,t);
  glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,w,h,0,GL_RGBA,GL_FLOAT,pixels);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);return t;
}
std::vector<float> render(GLuint p,const std::vector<float>& input,int iw,int ih,int ow,int oh) {
  auto src=texture(iw,ih,input.data()), dst=texture(ow,oh,nullptr);
  GLuint fb;glGenFramebuffers(1,&fb);glBindFramebuffer(GL_FRAMEBUFFER,fb);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,dst,0);
  if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("FBO");
  glUseProgram(p);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,src);glUniform1i(glGetUniformLocation(p,"input_color"),0);
  GLuint ubo;glGenBuffers(1,&ubo);glBindBuffer(GL_UNIFORM_BUFFER,ubo);float dims[]={(float)iw,(float)ih,(float)ow,(float)oh};
  glBufferData(GL_UNIFORM_BUFFER,sizeof(dims),dims,GL_STATIC_DRAW);glUniformBlockBinding(p,glGetUniformBlockIndex(p,"FsrInfo"),0);glBindBufferBase(GL_UNIFORM_BUFFER,0,ubo);
  glViewport(0,0,ow,oh);glDrawArrays(GL_TRIANGLES,0,6);std::vector<float> out(ow*oh*4);glReadPixels(0,0,ow,oh,GL_RGBA,GL_FLOAT,out.data());
  if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("OpenGL error");
  glDeleteBuffers(1,&ubo);glDeleteFramebuffers(1,&fb);glDeleteTextures(1,&src);glDeleteTextures(1,&dst);return out;
}
int main(int argc,char** argv) { try {
  CGLPixelFormatAttribute attrs[]={kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,(CGLPixelFormatAttribute)0};
  CGLPixelFormatObj fmt;GLint n;CGLContextObj ctx;
  if(CGLChoosePixelFormat(attrs,&fmt,&n)||CGLCreateContext(fmt,nullptr,&ctx)||CGLSetCurrentContext(ctx))throw std::runtime_error("CGL context");
  std::cout<<"GPU "<<glGetString(GL_RENDERER)<<"\n";
  GLuint vao,vbo;glGenVertexArrays(1,&vao);glBindVertexArray(vao);glGenBuffers(1,&vbo);glBindBuffer(GL_ARRAY_BUFFER,vbo);
  float quad[]={-1,-1,1,-1,-1,1,-1,1,1,-1,1,1};glBufferData(GL_ARRAY_BUFFER,sizeof(quad),quad,GL_STATIC_DRAW);glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,0);glEnableVertexAttribArray(0);
  GLuint easu=program(argv[1]),reference=program(argv[2]),rcas=program(argv[3]),rcasReference=program(argv[4]);
  for(int fixture=0;fixture<5;fixture++)for(int ow:{31,48,67}) {
    const int iw=23,ih=17,oh=ow*ih/iw;std::vector<float> in(iw*ih*4);
    for(int y=0;y<ih;y++)for(int x=0;x<iw;x++) {
      int i=(y*iw+x)*4;float edge=x>y*1.3f?1.f:0.f;
      in[i]=fixture==0?edge:fixture==1?(x%2):float(x)/(iw-1);
      in[i+1]=fixture==0?edge:fixture==1?(y%2):float(y)/(ih-1);
      in[i+2]=fixture==0?edge:fixture==1?((x+y)%2):.25f;
      if(fixture==3)in[i]=in[i+1]=in[i+2]=0;
      if(fixture==4)in[i]=in[i+1]=in[i+2]=1;
      in[i+3]=1;
    }
    auto actual=render(easu,in,iw,ih,ow,oh), expected=render(reference,in,iw,ih,ow,oh);
    float error=0;for(size_t i=0;i<actual.size();i++) {if(!std::isfinite(actual[i]))throw std::runtime_error("nonfinite EASU");error=std::max(error,std::abs(actual[i]-expected[i]));}
    if(error>0.002)throw std::runtime_error("gather reference mismatch "+std::to_string(error));
    auto sharp=render(rcas,actual,ow,oh,ow,oh);
    auto referenceSharp=render(rcasReference,expected,ow,oh,ow,oh);
    float sharpError=0;
    for(size_t i=0;i<sharp.size();i++)sharpError=std::max(sharpError,std::abs(sharp[i]-referenceSharp[i]));
    if(sharpError>0.002)throw std::runtime_error("RCAS reference mismatch "+std::to_string(sharpError));
    for(float v:sharp)if(!std::isfinite(v)||v<0||v>1)throw std::runtime_error("invalid RCAS");
    // Independent alpha ramp and transparent boundaries: coverage must be
    // bilinear after EASU, bit-identical after RCAS, and RGB premultiplied.
    for(int y=0;y<ih;y++)for(int x=0;x<iw;x++){int i=(y*iw+x)*4;float a=float(x)/(iw-1);for(int c=0;c<3;c++)in[i+c]*=a;in[i+3]=a;}
    actual=render(easu,in,iw,ih,ow,oh);sharp=render(rcas,actual,ow,oh,ow,oh);
    for(int y=0;y<oh;y++)for(int x=0;x<ow;x++) {int i=(y*ow+x)*4;float alpha=std::clamp(((x+.5f)*iw/ow-.5f)/(iw-1),0.f,1.f);
      if(std::abs(actual[i+3]-alpha)>0.00001||sharp[i+3]!=actual[i+3])throw std::runtime_error("alpha changed");
      for(int c=0;c<3;c++)if(!std::isfinite(sharp[i+c])||sharp[i+c]<0||sharp[i+c]>alpha+0.00001)throw std::runtime_error("premultiplication");}
    std::cout<<"fixture="<<fixture<<" size="<<ow<<"x"<<oh<<" max_reference_error="<<error<<" rcas_reference_error="<<sharpError<<" alpha=pass\n";
  }
  return 0;
} catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;} }
