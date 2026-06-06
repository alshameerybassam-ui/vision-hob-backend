import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'npm:@supabase/supabase-js@2.46.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { imageUrl, enhancementType } = await req.json()

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
        },
      }
    )

    const authHeader = req.headers.get('authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'No authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { data: { user }, error: userError } = await supabase.auth.getUser(
      authHeader.replace('Bearer ', '')
    )

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Invalid token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { data: profile } = await supabase
      .from('profiles')
      .select('credits')
      .eq('id', user.id)
      .single()

    if (!profile || profile.credits <= 0) {
      return new Response(
        JSON.stringify({ error: 'Insufficient credits' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Map enhancement types to Replicate models (2026 updated models)
    const modelMap: Record<string, string> = {
      'upscale': 'topazlabs/topaz-image-upscale',  // Best overall upscaler
      'restore': 'tencentarc/gfpgan',  // Face restoration
      'colorize': 'arielreplicate/deoldify_image',  // Colorization
      'enhance': 'philz1337/clarity-upscaler',  // Clarity enhancement
    }

    const model = modelMap[enhancementType] || modelMap['upscale']

    // Call Replicate API
    const replicateResponse = await fetch('https://api.replicate.com/v1/predictions', {
      method: 'POST',
      headers: {
        'Authorization': `Token ${Deno.env.get('REPLICATE_API_KEY')}`,
        'Content-Type': 'application/json',
        'Prefer': 'wait',
      },
      body: JSON.stringify({
        version: model,
        input: {
          image: imageUrl,
          scale: 2,
          face_enhance: true,
        },
      }),
    })

    if (!replicateResponse.ok) {
      const error = await replicateResponse.json()
      throw new Error(error.detail || 'Replicate API error')
    }

    const replicateData = await replicateResponse.json()
    const enhancedUrl = replicateData.output || replicateData.urls?.get

    const { error: dbError } = await supabase
      .from('image_enhancements')
      .insert({
        user_id: user.id,
        original_url: imageUrl,
        enhanced_url: enhancedUrl,
        enhancement_type: enhancementType,
        status: 'completed',
        completed_at: new Date().toISOString(),
      })

    if (dbError) {
      console.error('Database error:', dbError)
    }

    await supabase.rpc('deduct_credits', {
      user_uuid: user.id,
      amount: 1,
    })

    return new Response(
      JSON.stringify({
        success: true,
        enhancedUrl,
        remainingCredits: profile.credits - 1,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Revive Error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to enhance image', details: (error as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
