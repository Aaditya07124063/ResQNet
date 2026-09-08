import { Router } from 'express';
import { requireAuth } from '../middleware/authMiddleware';
import { authRouter } from './authRoutes';
import { profileRouter } from './profileRoutes';
import { profileImageRouter } from './profileImageRoutes';
import { reportRouter } from './reportRoutes';
import { sosRouter } from './sosRoutes';
import { employeeRouter } from './employee';
import { deviceRouter } from './deviceRoutes';
import { internalRouter } from './internalRoutes';
import { conversationRouter } from './conversationRoutes';
import { nearbyAlertRouter } from './nearbyAlertRoutes';

export const router = Router();

router.use('/auth', authRouter);
router.use('/profile', profileRouter);
router.use('/profile', profileImageRouter);
router.use('/reports', reportRouter);
router.use('/sos', sosRouter);
router.use('/employee', employeeRouter);
router.use('/devices', deviceRouter);
router.use('/internal', internalRouter);
router.use('/conversations', conversationRouter);
router.use('/nearby-alerts', nearbyAlertRouter);

// Minimal authenticated identity-check endpoint, useful for the Flutter
// client to verify its token/backend wiring end-to-end. Group-chat routes
// are added in their own later phase rather than scaffolded empty here.
router.get('/me', requireAuth, (req, res) => {
  res.json({ user: req.authUser });
});
