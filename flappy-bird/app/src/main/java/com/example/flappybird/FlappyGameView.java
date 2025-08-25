package com.example.flappybird;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Random;

public class FlappyGameView extends SurfaceView implements SurfaceHolder.Callback, Runnable {
    private Thread gameThread;
    private volatile boolean isRunning;
    private long lastFrameTimeNanos;

    private final Paint backgroundPaint = new Paint();
    private final Paint groundPaint = new Paint();
    private final Paint birdPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pipePaint = new Paint();
    private final Paint scorePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint messagePaint = new Paint(Paint.ANTI_ALIAS_FLAG);

    private final RectF rect = new RectF();
    private final Random random = new Random();

    // World parameters
    private float worldWidth;
    private float worldHeight;
    private float groundHeight;

    // Bird parameters
    private float birdX;
    private float birdY;
    private float birdRadius;
    private float birdVelocityY;
    private float gravity;
    private float flapImpulse;

    // Pipes
    private static class PipePair {
        float x;
        float gapCenterY;
        float gapHeight;
        boolean scored;

        PipePair(float x, float gapCenterY, float gapHeight) {
            this.x = x;
            this.gapCenterY = gapCenterY;
            this.gapHeight = gapHeight;
            this.scored = false;
        }
    }

    private final List<PipePair> pipes = new ArrayList<>();
    private float pipeWidth;
    private float pipeSpeed;
    private float pipeSpacing;

    // Game state
    private int score;
    private boolean gameOver;
    private boolean started;

    public FlappyGameView(Context context) {
        super(context);
        getHolder().addCallback(this);
        setFocusable(true);

        backgroundPaint.setColor(Color.rgb(135, 206, 235)); // sky blue
        groundPaint.setColor(Color.rgb(222, 184, 135)); // burlywood for ground
        birdPaint.setColor(Color.YELLOW);
        pipePaint.setColor(Color.rgb(34, 139, 34)); // forest green

        scorePaint.setColor(Color.WHITE);
        scorePaint.setTextSize(72f);
        scorePaint.setTextAlign(Paint.Align.CENTER);
        scorePaint.setShadowLayer(8f, 0f, 0f, Color.BLACK);

        messagePaint.setColor(Color.WHITE);
        messagePaint.setTextSize(48f);
        messagePaint.setTextAlign(Paint.Align.CENTER);
        messagePaint.setShadowLayer(6f, 0f, 0f, Color.BLACK);
    }

    private void initializeWorld(int width, int height) {
        this.worldWidth = width;
        this.worldHeight = height;
        this.groundHeight = Math.max(48f, height * 0.10f);

        this.birdRadius = Math.max(18f, height * 0.03f);
        this.birdX = width * 0.35f;
        this.birdY = height * 0.5f;
        this.birdVelocityY = 0f;
        this.gravity = Math.max(900f, height * 2.4f); // px/s^2
        this.flapImpulse = Math.max(420f, height * 1.0f); // px/s upward

        this.pipeWidth = Math.max(64f, width * 0.12f);
        this.pipeSpeed = Math.max(180f, width * 0.35f); // px/s leftward
        this.pipeSpacing = Math.max(240f, width * 0.9f); // distance between pipe pairs

        this.score = 0;
        this.gameOver = false;
        this.started = false;

        pipes.clear();
        float startX = width + 200f;
        for (int i = 0; i < 4; i++) {
            float x = startX + i * pipeSpacing;
            pipes.add(createRandomPipe(x));
        }
    }

    private PipePair createRandomPipe(float x) {
        float usableHeight = worldHeight - groundHeight;
        float gapHeight = Math.max(usableHeight * 0.22f, 260f);
        float margin = gapHeight * 0.5f + 60f;
        float centerY = margin + random.nextFloat() * (usableHeight - 2 * margin);
        return new PipePair(x, centerY, gapHeight);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        int w = getWidth();
        int h = getHeight();
        if (w == 0 || h == 0) {
            w = getResources().getDisplayMetrics().widthPixels;
            h = getResources().getDisplayMetrics().heightPixels;
        }
        initializeWorld(w, h);
        resume();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        initializeWorld(width, height);
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        pause();
    }

    public void resume() {
        if (gameThread == null || !gameThread.isAlive()) {
            isRunning = true;
            gameThread = new Thread(this, "FlappyGameThread");
            gameThread.start();
        } else {
            isRunning = true;
        }
    }

    public void pause() {
        isRunning = false;
        if (gameThread != null) {
            try {
                gameThread.join(500);
            } catch (InterruptedException ignored) {
            }
        }
    }

    @Override
    public void run() {
        lastFrameTimeNanos = System.nanoTime();
        SurfaceHolder holder = getHolder();

        while (true) {
            if (!isRunning) {
                try { Thread.sleep(32); } catch (InterruptedException ignored) {}
                continue;
            }

            long now = System.nanoTime();
            float dt = (now - lastFrameTimeNanos) / 1_000_000_000f;
            if (dt > 0.05f) dt = 0.05f;
            lastFrameTimeNanos = now;

            update(dt);

            Canvas canvas = holder.lockCanvas();
            if (canvas != null) {
                try {
                    drawFrame(canvas);
                } finally {
                    holder.unlockCanvasAndPost(canvas);
                }
            }

            try { Thread.sleep(12); } catch (InterruptedException ignored) {}
        }
    }

    private void update(float dt) {
        if (!started || gameOver) {
            birdY += Math.sin(System.nanoTime() / 200_000_000.0) * 0.5f;
            return;
        }

        birdVelocityY += gravity * dt;
        birdY += birdVelocityY * dt;

        if (birdY - birdRadius < 0) {
            birdY = birdRadius;
            birdVelocityY = 0;
        }
        if (birdY + birdRadius > worldHeight - groundHeight) {
            birdY = worldHeight - groundHeight - birdRadius;
            gameOver = true;
        }

        float leftBound = -pipeWidth - 10f;
        float rightSpawnX = worldWidth + pipeSpacing * 0.5f;
        Iterator<PipePair> it = pipes.iterator();
        while (it.hasNext()) {
            PipePair p = it.next();
            p.x -= pipeSpeed * dt;
            if (!p.scored && p.x + pipeWidth < birdX) {
                score += 1;
                p.scored = true;
            }
            if (p.x + pipeWidth < leftBound) {
                it.remove();
            }
        }
        while (pipes.size() < 4) {
            float lastX = pipes.isEmpty() ? rightSpawnX : pipes.get(pipes.size() - 1).x;
            pipes.add(createRandomPipe(Math.max(rightSpawnX, lastX + pipeSpacing)));
        }

        for (PipePair p : pipes) {
            float topBottom = p.gapCenterY - p.gapHeight * 0.5f;
            float gapBottom = p.gapCenterY + p.gapHeight * 0.5f;
            if (circleIntersectsRect(birdX, birdY, birdRadius, p.x, 0, p.x + pipeWidth, topBottom)) {
                gameOver = true;
                break;
            }
            if (circleIntersectsRect(birdX, birdY, birdRadius, p.x, gapBottom, p.x + pipeWidth, worldHeight - groundHeight)) {
                gameOver = true;
                break;
            }
        }
    }

    private boolean circleIntersectsRect(float cx, float cy, float cr, float left, float top, float right, float bottom) {
        float closestX = clamp(cx, left, right);
        float closestY = clamp(cy, top, bottom);
        float dx = cx - closestX;
        float dy = cy - closestY;
        return dx * dx + dy * dy <= cr * cr;
    }

    private float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }

    private void drawFrame(Canvas canvas) {
        canvas.drawColor(backgroundPaint.getColor());

        for (PipePair p : pipes) {
            float left = p.x;
            float right = p.x + pipeWidth;
            float topPipeBottom = p.gapCenterY - p.gapHeight * 0.5f;
            float bottomPipeTop = p.gapCenterY + p.gapHeight * 0.5f;

            rect.set(left, 0, right, topPipeBottom);
            canvas.drawRect(rect, pipePaint);
            rect.set(left, bottomPipeTop, right, worldHeight - groundHeight);
            canvas.drawRect(rect, pipePaint);
        }

        rect.set(0, worldHeight - groundHeight, worldWidth, worldHeight);
        canvas.drawRect(rect, groundPaint);

        canvas.drawCircle(birdX, birdY, birdRadius, birdPaint);

        canvas.drawText(String.valueOf(score), worldWidth * 0.5f, worldHeight * 0.18f, scorePaint);

        if (!started) {
            canvas.drawText("Tap to start", worldWidth * 0.5f, worldHeight * 0.4f, messagePaint);
        } else if (gameOver) {
            canvas.drawText("Game Over - tap to retry", worldWidth * 0.5f, worldHeight * 0.4f, messagePaint);
        }
    }

    private void resetGame() {
        initializeWorld((int) worldWidth, (int) worldHeight);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (event.getAction() == MotionEvent.ACTION_DOWN) {
            if (!started) {
                started = true;
                birdVelocityY = -flapImpulse;
            } else if (gameOver) {
                resetGame();
                started = true;
            } else {
                birdVelocityY = -flapImpulse;
            }
            return true;
        }
        return super.onTouchEvent(event);
    }
}

