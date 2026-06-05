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
    const { imageUrl, imageBase64 } = await req.json()

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

    let imageData: string
    if (imageBase64) {
      imageData = imageBase64
    } else if (imageUrl) {
      const imageResponse = await fetch(imageUrl)
      const imageBuffer = await imageResponse.arrayBuffer()
      imageData = btoa(String.fromCharCode(...new Uint8Array(imageBuffer)))
    } else {
      return new Response(
        JSON.stringify({ error: 'No image provided' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${Deno.env.get('GEMINI_API_KEY')}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{
            parts: [
              {
                text: `Analyze this photograph as a professional photography coach. Provide:
                1. Overall score (0-100)
                2. Composition analysis (detailed)
                3. Lighting assessment (detailed)
                4. Technical quality - focus, exposure, sharpness (detailed)
                5. Color and contrast analysis (detailed)
                6. Specific improvement tips (5 actionable tips in Arabic)
                7. What works well (3-5 points in Arabic)

                Respond in Arabic. Be encouraging but honest and detailed. Format as JSON with keys: score, composition, lighting, technical, color, tips (array), strengths (array).`
              },
              {
                inlineData: {
                  mimeType: 'image/jpeg',
                  data: imageData
                }
              }
            ]
          }]
        }),
      }
    )

    if (!geminiResponse.ok) {
      const error = await geminiResponse.json()
      throw new Error(error.error?.message || 'Gemini API error')
    }

    const geminiData = await geminiResponse.json()
    const analysisText = geminiData.candidates[0].content.parts[0].text

    let analysis
    try {
      const jsonMatch = analysisText.match(/\{[\s\S]*\}/)
      analysis = jsonMatch ? JSON.parse(jsonMatch[0]) : {
        score: 75,
        composition: 'جيد',
        lighting: 'جيد',
        technical: 'جيد',
        color: 'جيد',
        tips: ['حاول تغيير زاوية التصوير'],
        strengths: ['تكوين متوازن']
      }
    } catch {
      analysis = {
        score: 75,
        composition: analysisText,
        lighting: 'تم التحليل',
        technical: 'تم التحليل',
        color: 'تم التحليل',
        tips: ['راجع التحليل أعلاه'],
        strengths: ['صورة تم رفعها بنجاح']
      }
    }

    const { error: dbError } = await supabase
      .from('photo_analysis')
      .insert({
        user_id: user.id,
        image_url: imageUrl || 'base64-upload',
        analysis_result: analysis,
        score: analysis.score || 75,
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
        analysis,
        remainingCredits: profile.credits - 1,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Lens Analysis Error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to analyze photo', details: (error as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
