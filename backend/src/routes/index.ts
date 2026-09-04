import { Router } from 'express';
import { requireAuth } from '../middleware/authMiddleware';
import { authRouter } from './authRoutes';
import { profileRouter } from './profileRoutes';

export const router = Router();

router.use('/auth', authRouter);
router.use('/profile', profileRouter);

// Minimal authenticated identity-check endpoint, useful for the Flutter
// client to verify its token/backend wiring end-to-end. Resource routes
// (profile, trusted contacts, groups, messages, sos, locations, alerts,
// employee portal) are added in their own later phases rather than
// scaffolded empty here.
router.get('/me', requireAuth, (req, res) => {
  res.json({ user: req.authUser });
});
