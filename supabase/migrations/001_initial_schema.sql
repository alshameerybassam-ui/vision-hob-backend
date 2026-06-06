-- ==========================================
-- Vision Hub - Initial Database Schema
-- ==========================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ==========================================
-- 1. Profiles Table (extends auth.users)
-- ==========================================
CREATE TABLE IF NOT EXISTS profiles (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  full_name TEXT,
  avatar_url TEXT,
  bio TEXT,
  credits INTEGER DEFAULT 10,
  plan TEXT DEFAULT 'free' CHECK (plan IN ('free', 'pro', 'enterprise')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = id);

-- Trigger to create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, credits)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'full_name', 10);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ==========================================
-- 2. Projects Table (FrameAI)
-- ==========================================
CREATE TABLE IF NOT EXISTS projects (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  brand_colors JSONB DEFAULT '[]',
  style TEXT DEFAULT 'modern',
  generated_images TEXT[] DEFAULT '{}',
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'archived', 'deleted')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own projects"
  ON projects FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create projects"
  ON projects FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own projects"
  ON projects FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own projects"
  ON projects FOR DELETE
  USING (auth.uid() = user_id);

-- ==========================================
-- 3. Photo Analysis Table (Lens Coach)
-- ==========================================
CREATE TABLE IF NOT EXISTS photo_analysis (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  image_url TEXT NOT NULL,
  analysis_result JSONB DEFAULT '{}',
  score INTEGER CHECK (score >= 0 AND score <= 100),
  feedback JSONB DEFAULT '[]',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE photo_analysis ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own analysis"
  ON photo_analysis FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create analysis"
  ON photo_analysis FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own analysis"
  ON photo_analysis FOR DELETE
  USING (auth.uid() = user_id);

-- ==========================================
-- 4. Image Enhancements Table (Revive)
-- ==========================================
CREATE TABLE IF NOT EXISTS image_enhancements (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  original_url TEXT NOT NULL,
  enhanced_url TEXT,
  enhancement_type TEXT NOT NULL CHECK (enhancement_type IN ('upscale', 'restore', 'colorize', 'enhance')),
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

ALTER TABLE image_enhancements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own enhancements"
  ON image_enhancements FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create enhancements"
  ON image_enhancements FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own enhancements"
  ON image_enhancements FOR UPDATE
  USING (auth.uid() = user_id);

-- ==========================================
-- 5. Credit Transactions Table
-- ==========================================
CREATE TABLE IF NOT EXISTS credit_transactions (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  amount INTEGER NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('purchase', 'usage', 'bonus', 'refund')),
  description TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE credit_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own transactions"
  ON credit_transactions FOR SELECT
  USING (auth.uid() = user_id);

-- ==========================================
-- 6. Storage Buckets Setup
-- ==========================================
-- Create storage buckets for images
INSERT INTO storage.buckets (id, name, public) 
VALUES 
  ('projects', 'projects', true),
  ('photos', 'photos', true),
  ('enhancements', 'enhancements', true)
ON CONFLICT (id) DO NOTHING;

-- Storage RLS Policies
CREATE POLICY "Allow authenticated uploads to projects"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'projects' AND
    auth.role() = 'authenticated'
  );

CREATE POLICY "Allow public read access to projects"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'projects');

CREATE POLICY "Allow authenticated uploads to photos"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'photos' AND
    auth.role() = 'authenticated'
  );

CREATE POLICY "Allow public read access to photos"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'photos');

CREATE POLICY "Allow authenticated uploads to enhancements"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'enhancements' AND
    auth.role() = 'authenticated'
  );

CREATE POLICY "Allow public read access to enhancements"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'enhancements');

-- ==========================================
-- 7. Functions & Triggers
-- ==========================================

-- Update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_projects_updated_at
  BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Deduct credits function
CREATE OR REPLACE FUNCTION deduct_credits(user_uuid UUID, amount INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
  current_credits INTEGER;
BEGIN
  SELECT credits INTO current_credits FROM profiles WHERE id = user_uuid;

  IF current_credits >= amount THEN
    UPDATE profiles SET credits = credits - amount WHERE id = user_uuid;

    INSERT INTO credit_transactions (user_id, amount, type, description)
    VALUES (user_uuid, -amount, 'usage', 'AI tool usage');

    RETURN TRUE;
  ELSE
    RETURN FALSE;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==========================================
-- 8. Indexes for Performance
-- ==========================================
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects(user_id);
CREATE INDEX IF NOT EXISTS idx_photo_analysis_user_id ON photo_analysis(user_id);
CREATE INDEX IF NOT EXISTS idx_enhancements_user_id ON image_enhancements(user_id);
CREATE INDEX IF NOT EXISTS idx_credit_transactions_user_id ON credit_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_projects_created_at ON projects(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_photo_analysis_created_at ON photo_analysis(created_at DESC);

-- ==========================================
-- 9. Initial Data (Optional)
-- ==========================================
-- Add default credits for testing (remove in production)
-- UPDATE profiles SET credits = 10 WHERE credits = 0;
