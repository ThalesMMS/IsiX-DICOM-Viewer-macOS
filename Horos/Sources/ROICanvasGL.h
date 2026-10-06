// The ROIs' immediate-mode drawing, sent to the view's Core Graphics canvas
// (HorosROICanvas) instead of OpenGL. Each call takes the arguments of the
// OpenGL function it replaces; with no canvas current, nothing is drawn.
//
// The types and enumerants are the canvas's own, with OpenGL's
// names and values, so that the drawing code reads as it always did without
// OpenGL's headers.

#import "Horos-Swift.h"
#include <stdint.h>

#ifndef GL_LINES
typedef uint32_t GLenum;
typedef uint32_t GLbitfield;
typedef uint32_t GLuint;
typedef int32_t GLint;
typedef float GLfloat;
typedef double GLdouble;
typedef uint8_t GLubyte;
typedef uint16_t GLushort;

// Primitives
#define GL_POINTS 0x0000
#define GL_LINES 0x0001
#define GL_LINE_LOOP 0x0002
#define GL_LINE_STRIP 0x0003
#define GL_TRIANGLES 0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLE_FAN 0x0006
#define GL_QUADS 0x0007
#define GL_QUAD_STRIP 0x0008
#define GL_POLYGON 0x0009
// Capabilities
#define GL_POINT_SMOOTH 0x0B10
#define GL_LINE_SMOOTH 0x0B20
#define GL_LINE_STIPPLE 0x0B24
#define GL_POLYGON_SMOOTH 0x0B41
#define GL_DEPTH_TEST 0x0B71
#define GL_BLEND 0x0BE2
#define GL_MAP1_VERTEX_3 0x0D97
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_RECTANGLE_EXT 0x84F5
// Blending
#define GL_ONE 1
#define GL_SRC_ALPHA 0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_FUNC_ADD 0x8006
// Matrices and attribute groups
#define GL_MODELVIEW 0x1700
#define GL_PROJECTION 0x1701
#define GL_CURRENT_BIT 0x00000001
#define GL_POINT_BIT 0x00000002
#define GL_LINE_BIT 0x00000004
#define GL_ENABLE_BIT 0x00002000
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_TEXTURE_BIT 0x00040000
// Hints
#define GL_NICEST 0x1102
#define GL_POINT_SMOOTH_HINT 0x0C51
#define GL_LINE_SMOOTH_HINT 0x0C52
#define GL_POLYGON_SMOOTH_HINT 0x0C53
#define GL_TRUE 1
#define GL_FALSE 0
#endif

static inline HorosROICanvas *ROICanvasCurrent(void) { return [HorosROICanvas current]; }

/// A frame's graphics start with no stipple and no curve map left on.
static inline void roiResetFrameState(void) { [ROICanvasCurrent() resetFrameState]; }
static inline void roiBegin(GLenum mode) { [ROICanvasCurrent() begin: mode]; }
static inline void roiEnd(void) { [ROICanvasCurrent() end]; }
static inline void roiVertex2f(GLfloat x, GLfloat y) { [ROICanvasCurrent() vertexX: x y: y]; }
static inline void roiVertex2d(GLdouble x, GLdouble y) { [ROICanvasCurrent() vertexX: x y: y]; }
static inline void roiVertex3f(GLfloat x, GLfloat y, GLfloat z) { [ROICanvasCurrent() vertexX: x y: y z: z]; }
static inline void roiVertex3d(GLdouble x, GLdouble y, GLdouble z) { [ROICanvasCurrent() vertexX: x y: y z: z]; }
static inline void roiColor3f(GLfloat r, GLfloat g, GLfloat b) { [ROICanvasCurrent() colorR: r g: g b: b a: 1]; }
static inline void roiColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) { [ROICanvasCurrent() colorR: r g: g b: b a: a]; }
static inline void roiColor3d(GLdouble r, GLdouble g, GLdouble b) { [ROICanvasCurrent() colorR: r g: g b: b a: 1]; }
static inline void roiColor4d(GLdouble r, GLdouble g, GLdouble b, GLdouble a) { [ROICanvasCurrent() colorR: r g: g b: b a: a]; }
static inline void roiColor3ub(GLubyte r, GLubyte g, GLubyte b) { [ROICanvasCurrent() colorR: r / 255.0 g: g / 255.0 b: b / 255.0 a: 1]; }
static inline void roiLineWidth(GLfloat w) { [ROICanvasCurrent() lineWidth: w]; }
static inline void roiPointSize(GLfloat s) { [ROICanvasCurrent() pointSize: s]; }
static inline void roiEnable(GLenum cap) { [ROICanvasCurrent() enable: cap]; }
static inline void roiDisable(GLenum cap) { [ROICanvasCurrent() disable: cap]; }
static inline void roiBlendFunc(GLenum source, GLenum destination) { [ROICanvasCurrent() blendSource: source destination: destination]; }
static inline void roiLineStipple(GLint factor, GLushort pattern) { [ROICanvasCurrent() lineStippleFactor: factor pattern: pattern]; }
static inline void roiPushAttrib(GLbitfield mask) { [ROICanvasCurrent() pushAttributes]; }
static inline void roiPopAttrib(void) { [ROICanvasCurrent() popAttributes]; }
static inline void roiLoadIdentity(void) { [ROICanvasCurrent() loadIdentity]; }
static inline void roiPushMatrix(void) { [ROICanvasCurrent() pushMatrix]; }
static inline void roiPopMatrix(void) { [ROICanvasCurrent() popMatrix]; }
static inline void roiScalef(GLfloat x, GLfloat y, GLfloat z) { [ROICanvasCurrent() scaleX: x y: y z: z]; }
static inline void roiTranslatef(GLfloat x, GLfloat y, GLfloat z) { [ROICanvasCurrent() translateX: x y: y z: z]; }
static inline void roiRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z) { [ROICanvasCurrent() rotate: z < 0 ? -angle : angle]; }
static inline void roiMultMatrixd(const GLdouble *m) { [ROICanvasCurrent() multMatrix: m]; }
// The canvas keeps one matrix, projection and model-view together: every caller
// draws with the projection the identity.
static inline void roiMatrixMode(GLenum mode) {}
// Hints and the blend equation, which is always GL_FUNC_ADD here, change nothing.
static inline void roiHint(GLenum target, GLenum mode) {}
static inline void roiBlendEquation(GLenum mode) {}
static inline void roiMap1f(GLenum target, GLfloat u1, GLfloat u2, GLint stride, GLint order, const GLfloat *points) { [ROICanvasCurrent() map1Points: points count: order]; }
static inline void roiEvalCoord1f(GLfloat u) { [ROICanvasCurrent() evalCoord: u]; }
